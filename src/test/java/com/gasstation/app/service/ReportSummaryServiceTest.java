package com.gasstation.app.service;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.db.Db;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.Transaction;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ReportSummaryServiceTest {

    @TempDir
    Path tempDir;

    private Path testDbPath;
    private CustomerDao customerDao;
    private TransactionDao transactionDao;
    private ReportSummaryService reportSummaryService;

    @BeforeEach
    void setUp() throws Exception {
        testDbPath = tempDir.resolve("report-summary-test.db");
        System.setProperty(Db.DB_PATH_PROPERTY, testDbPath.toString());
        Db.init();
        customerDao = new CustomerDao();
        transactionDao = new TransactionDao();
        reportSummaryService = new ReportSummaryService(customerDao, transactionDao);
    }

    @AfterEach
    void tearDown() throws Exception {
        System.clearProperty(Db.DB_PATH_PROPERTY);
        Files.deleteIfExists(testDbPath);
    }

    @Test
    void buildsPeriodSummaryWithPostedTransactionsOnlyAndTotals() throws Exception {
        long activeCustomer = insertCustomer("Active Customer", "9999992001", 1);
        long inactiveCustomer = insertCustomer("Inactive Customer", "9999992002", 0);
        insertCustomer("No Activity", "9999992003", 1);

        long voidTxn = transactionDao.insert(txn(activeCustomer, "2026-01-03", "DEBIT", 5_000L));
        transactionDao.voidTransaction(voidTxn, "Correction");
        transactionDao.insert(txn(activeCustomer, "2026-01-04", "DEBIT", 10_000L));
        transactionDao.insert(txn(activeCustomer, "2026-01-05", "CREDIT", 4_000L));
        transactionDao.insert(txn(inactiveCustomer, "2026-01-06", "CREDIT", 2_500L));
        transactionDao.insert(txn(activeCustomer, "2026-02-01", "DEBIT", 99_999L));

        ReportSummaryService.PeriodSummary summary = reportSummaryService.buildPeriodSummary(
                LocalDate.parse("2026-01-01"), LocalDate.parse("2026-01-31"));

        assertEquals(2, summary.rows().size());
        assertEquals(10_000L, summary.totalDebitsPaise());
        assertEquals(6_500L, summary.totalCreditsPaise());
        assertEquals(-3_500L, summary.netPaise());

        ReportSummaryService.PeriodCustomerSummary first = summary.rows().get(0);
        assertEquals(activeCustomer, first.customerId());
        assertEquals(10_000L, first.debitsPaise());
        assertEquals(4_000L, first.creditsPaise());
        assertEquals(-6_000L, first.netPaise());
    }

    @Test
    void rejectsInvertedDateRange() {
        assertThrows(IllegalArgumentException.class, () -> reportSummaryService.buildPeriodSummary(
                LocalDate.parse("2026-02-01"), LocalDate.parse("2026-01-01")));
    }

    private long insertCustomer(String name, String phone, int active) throws Exception {
        Customer customer = new Customer(name, phone, null, null, active);
        customer.setDueDays(30);
        customer.setGraceDays(0);
        return customerDao.insert(customer);
    }

    private static Transaction txn(long customerId, String date, String type, long amountPaise) {
        Transaction transaction = new Transaction();
        transaction.setCustomerId(customerId);
        transaction.setTxnDate(date);
        transaction.setTxnType(type);
        transaction.setAmountPaise(amountPaise);
        return transaction;
    }
}
