package com.gasstation.app;

import com.gasstation.app.model.Customer;
import com.gasstation.app.model.CustomerKpi;
import com.gasstation.app.model.Transaction;
import com.gasstation.app.service.CustomerKpiService;
import com.gasstation.app.service.InterestCalculator;
import com.gasstation.app.service.ReminderTemplateService;
import com.gasstation.app.util.MoneyUtil;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.List;

/**
 * Dependency-free smoke checks for core business logic.
 *
 * This can run even when Maven Central is unavailable:
 *   javac -cp src/main/java -d target/smoke-tests src/test/java/com/gasstation/app/BusinessLogicSmokeTest.java
 *   java -cp target/smoke-tests:src/main/java com.gasstation.app.BusinessLogicSmokeTest
 */
public final class BusinessLogicSmokeTest {
    private BusinessLogicSmokeTest() {}

    public static void main(String[] args) {
        moneyFormattingAndParsing();
        interestCalculationUsesIntegerPaise();
        interestCalculationAppliesCreditsFifo();
        customerKpiOutstandingStateUsesFifoAndGraceDays();
        reminderTemplateReplacesCorePlaceholders();
        transactionStatusDefaultsToPostedAndCanBeVoided();
        transactionDaoQueriesExcludeVoidedRows();
        importAmountValidationRejectsOverPreciseDecimals();
        System.out.println("BusinessLogicSmokeTest passed");
    }

    private static void moneyFormattingAndParsing() {
        assertEquals("₹1,234.50 parses to paise", 123450L, MoneyUtil.parseMoneyToPaise("₹1,234.50"));
        assertEquals("whole rupees parse to paise", 9900L, MoneyUtil.parseMoneyToPaise("99"));
        assertEquals("explicit plus sign parses to paise", 1234L, MoneyUtil.parseMoneyToPaise("+12.34"));
        assertEquals("negative amount parses to negative paise", -1234L, MoneyUtil.parseMoneyToPaise("-12.34"));
        assertEquals("negative paise formats with a leading sign", "₹-0.50", MoneyUtil.formatMoney(-50));
        assertThrows("blank amount is rejected", () -> MoneyUtil.parseMoneyToPaise("   "));
        assertThrows("more than 2 decimals are rejected", () -> MoneyUtil.parseMoneyToPaise("12.345"));
        assertThrows("non-numeric amount is rejected", () -> MoneyUtil.parseMoneyToPaise("abc"));
    }

    private static void interestCalculationUsesIntegerPaise() {
        Transaction debit = txn("2026-01-01", "DEBIT", 100_000L);
        InterestCalculator.StatementSummary summary = new InterestCalculator()
                .computeStatementWithRate(List.of(debit), LocalDate.parse("2026-01-01"), LocalDate.parse("2026-01-11"), 0.365);

        assertEquals("closing principal remains the debit amount", 100_000L, summary.closingPrincipalPaise);
        assertEquals("10 days interest at 36.5% annual on ₹1,000", 1_000L, summary.interestPaise);
        assertEquals("total due adds principal and interest", 101_000L, summary.totalDuePaise);
    }


    private static void interestCalculationAppliesCreditsFifo() {
        Transaction debit = txn("2026-01-01", "DEBIT", 100_000L);
        Transaction credit = txn("2026-01-06", "CREDIT", 40_000L);

        InterestCalculator.StatementSummary summary = new InterestCalculator()
                .computeStatementWithRate(List.of(debit, credit), LocalDate.parse("2026-01-01"), LocalDate.parse("2026-01-11"), 0.365);

        assertEquals("credit reduces outstanding principal FIFO", 60_000L, summary.closingPrincipalPaise);
        assertEquals("debits in range include the original debit", 100_000L, summary.debitsInRangePaise);
        assertEquals("credits in range include the payment", 40_000L, summary.creditsInRangePaise);
        assertEquals("interest accrues over changing principal segments", 800L, summary.interestPaise);
    }

    private static void customerKpiOutstandingStateUsesFifoAndGraceDays() {
        try {
            CustomerKpiService service = new CustomerKpiService();
            Method method = CustomerKpiService.class.getDeclaredMethod("computeOutstandingState", List.class, int.class, int.class, LocalDate.class);
            method.setAccessible(true);

            Object state = method.invoke(service, List.of(
                    txn("2026-01-01", "DEBIT", 100_000L),
                    txn("2026-01-10", "DEBIT", 50_000L),
                    txn("2026-01-15", "CREDIT", 75_000L)
            ), 10, 2, LocalDate.parse("2026-01-22"));

            assertEquals("FIFO KPI principal keeps unpaid bucket amounts", 75_000L, longField(state, "principalPaise"));
            assertEquals("only buckets beyond grace are overdue", 25_000L, longField(state, "overduePaise"));
            assertEquals("max days past due comes from oldest unpaid bucket", 11, intField(state, "maxDaysPastDue"));
        } catch (ReflectiveOperationException e) {
            throw new AssertionError("Unable to validate KPI outstanding-state behavior", e);
        }
    }

    private static void reminderTemplateReplacesCorePlaceholders() {
        Customer customer = new Customer();
        customer.setName("Ravi");

        CustomerKpi kpi = new CustomerKpi();
        kpi.setCustomer(customer);
        kpi.setMaxDaysOverdue(10);
        kpi.setOverdueAmountPaise(12_345L);
        kpi.setTotalDuePaise(20_000L);

        String message = new ReminderTemplateService()
                .render(ReminderTemplateService.TemplateKey.OVERDUE, ReminderTemplateService.Lang.EN, kpi);

        assertTrue("message includes customer name", message.contains("Ravi"));
        assertTrue("message includes overdue amount", message.contains("₹123.45"));
        assertTrue("message includes overdue days", message.contains("10"));
    }

    private static void transactionStatusDefaultsToPostedAndCanBeVoided() {
        Transaction txn = txn("2026-01-01", "DEBIT", 1_000L);
        assertEquals("new transactions default to POSTED", "POSTED", txn.getStatus());

        txn.setStatus("VOID");
        txn.setVoidReason("Correction");
        assertEquals("void status is stored without deleting the transaction", "VOID", txn.getStatus());
        assertEquals("void reason is preserved", "Correction", txn.getVoidReason());
    }


    private static void transactionDaoQueriesExcludeVoidedRows() {
        String source = readSource("src/main/java/com/gasstation/app/dao/TransactionDao.java");
        assertTrue("customer transaction list excludes VOID rows", source.contains("AND status <> 'VOID'"));
        assertTrue("all posted transaction list excludes VOID rows", source.contains("WHERE status <> 'VOID'"));
        assertTrue("voiding updates status instead of deleting", source.contains("SET status = 'VOID'"));
    }

    private static void importAmountValidationRejectsOverPreciseDecimals() {
        String screenSource = readSource("src/main/java/com/gasstation/app/ImportExcelScreen.java");
        String validatorSource = readSource("src/main/java/com/gasstation/app/service/TransactionImportValidator.java");
        assertTrue("transaction import delegates amount parsing to a non-UI validator", screenSource.contains("TransactionImportValidator.parseRupeesToPaise(text)"));
        assertTrue("transaction import validator delegates rupee parsing to MoneyUtil", validatorSource.contains("MoneyUtil.parseMoneyToPaise(t)"));
        assertEquals("MoneyUtil rejects over-precise import amounts", 0L, importStyleParseRupeesToPaise("12.345"));
        assertEquals("MoneyUtil accepts a valid rupee import amount", 1234L, importStyleParseRupeesToPaise("Rs. 12.34"));
    }

    private static long importStyleParseRupeesToPaise(String text) {
        String t = text == null ? "" : text.trim();
        if (t.isEmpty()) return 0;
        t = t.replace("Rs.", "")
                .replace("rs.", "")
                .replace("Rs", "")
                .replace("rs", "")
                .trim();
        try {
            return MoneyUtil.parseMoneyToPaise(t);
        } catch (IllegalArgumentException | ArithmeticException e) {
            return 0;
        }
    }

    private static String readSource(String path) {
        try {
            return Files.readString(Path.of(path));
        } catch (Exception e) {
            throw new AssertionError("Unable to read source file: " + path, e);
        }
    }

    private static long longField(Object target, String fieldName) throws ReflectiveOperationException {
        Field field = target.getClass().getDeclaredField(fieldName);
        field.setAccessible(true);
        return field.getLong(target);
    }

    private static int intField(Object target, String fieldName) throws ReflectiveOperationException {
        Field field = target.getClass().getDeclaredField(fieldName);
        field.setAccessible(true);
        return field.getInt(target);
    }

    private static Transaction txn(String date, String type, long amountPaise) {
        Transaction txn = new Transaction();
        txn.setTxnDate(date);
        txn.setTxnType(type);
        txn.setAmountPaise(amountPaise);
        return txn;
    }

    private static void assertEquals(String label, Object expected, Object actual) {
        if (!expected.equals(actual)) {
            throw new AssertionError(label + ": expected <" + expected + "> but was <" + actual + ">");
        }
    }

    private static void assertTrue(String label, boolean condition) {
        if (!condition) throw new AssertionError(label);
    }

    private static void assertThrows(String label, Runnable runnable) {
        try {
            runnable.run();
        } catch (IllegalArgumentException expected) {
            return;
        }
        throw new AssertionError(label + ": expected IllegalArgumentException");
    }
}
