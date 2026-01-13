package com.gasstation.app.service;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.SettingsDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.Transaction;
import com.gasstation.app.util.MoneyUtil;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.List;

/**
 * Exports Ledger PDFs using the same statement-text approach.
 * - VOID excluded (because TransactionDao.listByCustomer excludes VOID already)
 * - Creates either:
 *    A) one PDF per customer in a folder
 *    B) one combined PDF containing all customers
 */
public class LedgerPdfExportService {

    private final CustomerDao customerDao = new CustomerDao();
    private final TransactionDao txnDao = new TransactionDao();
    private final SettingsDao settingsDao = new SettingsDao();

    private final InterestCalculator calc = new InterestCalculator();
    private final PdfStatementService pdfService = new PdfStatementService();

    /**
     * Option B: Export one PDF per customer into a folder.
     */
    public void exportAllCustomersToFolder(Path folder, LocalDate from, LocalDate to) throws Exception {
        Files.createDirectories(folder);

        List<Customer> customers = customerDao.listAll();
        for (Customer c : customers) {
            String statement = buildStatementText(c, from, to);
            String safeName = makeSafeFileName(c.getName() + "-" + c.getPhone());
            Path pdf = pdfService.exportStatementText(safeName, statement, folder);
            // pdf path returned; you can log it if needed
        }
    }

    /**
     * Option A: Export one combined PDF for all customers.
     */
    public Path exportAllCustomersSinglePdf(Path outDir, String fileBaseName, LocalDate from, LocalDate to) throws Exception {
        Files.createDirectories(outDir);

        List<Customer> customers = customerDao.listAll();

        StringBuilder big = new StringBuilder();
        big.append("ALL CUSTOMERS LEDGER EXPORT\n");
        big.append("Generated: ").append(LocalDate.now()).append("\n");
        if (from != null && to != null) {
            big.append("Period: ").append(from).append(" to ").append(to).append("\n");
        } else {
            big.append("Period: FULL HISTORY\n");
        }
        big.append("\n============================================================\n\n");

        for (Customer c : customers) {
            big.append(buildStatementText(c, from, to));
            big.append("\n\n============================================================\n\n");
        }

        return pdfService.exportStatementText(fileBaseName, big.toString(), outDir);
    }

    /**
     * Builds statement text for ONE customer.
     * If from/to null => full history.
     */
    private String buildStatementText(Customer customer, LocalDate from, LocalDate to) throws Exception {
        List<Transaction> all = txnDao.listByCustomer(customer.getCustomerId());

        LocalDate resolvedFrom;
        LocalDate resolvedTo;

        if (from == null || to == null) {
            resolvedFrom = all.isEmpty() ? LocalDate.now() : LocalDate.parse(all.get(0).getTxnDate());
            resolvedTo = LocalDate.now();
        } else {
            resolvedFrom = from;
            resolvedTo = to;
        }

        final LocalDate fromDate = resolvedFrom;
        final LocalDate toDate = resolvedTo;

        List<Transaction> filtered = all.stream()
                .filter(t -> {
                    LocalDate d = LocalDate.parse(t.getTxnDate());
                    return !d.isBefore(fromDate) && !d.isAfter(toDate);
                })
                .toList();

        double rate = settingsDao.getDouble(CustomerKpiService.KEY_RATE, InterestCalculator.ANNUAL_RATE);

        var summary = calc.computeStatementWithRate(
                all,
                fromDate,
                toDate.plusDays(1), // [from, to)
                rate
        );

        StringBuilder sb = new StringBuilder();
        sb.append("Surya Lakshmi Fuels Point CREDIT STATEMENT\n");
        sb.append("-----------------------------------------\n");
        sb.append("Customer: ").append(customer.getName()).append("\n");
        sb.append("Phone   : ").append(customer.getPhone()).append("\n");
        sb.append("Period  : ").append(fromDate).append(" to ").append(toDate).append("\n\n");

        sb.append(String.format("Opening Principal : %s\n", MoneyUtil.formatMoney(summary.openingPrincipalPaise)));
        sb.append(String.format("Debits in Period  : %s\n", MoneyUtil.formatMoney(summary.debitsInRangePaise)));
        sb.append(String.format("Credits in Period : %s\n", MoneyUtil.formatMoney(summary.creditsInRangePaise)));
        sb.append(String.format("Closing Principal : %s\n", MoneyUtil.formatMoney(summary.closingPrincipalPaise)));
        sb.append(String.format("Interest (%.2f%%)  : %s\n", rate * 100.0, MoneyUtil.formatMoney(summary.interestPaise)));
        sb.append(String.format("TOTAL DUE         : %s\n\n", MoneyUtil.formatMoney(summary.totalDuePaise)));

        sb.append("DATE       TYPE     AMOUNT        BALANCE       REF\n");
        sb.append("------------------------------------------------------\n");

        long running = summary.openingPrincipalPaise;
        for (Transaction t : filtered) {
            if ("DEBIT".equalsIgnoreCase(t.getTxnType())) running += t.getAmountPaise();
            else running -= t.getAmountPaise();

            sb.append(String.format(
                    "%-10s %-7s %-12s %-12s %s\n",
                    t.getTxnDate(),
                    t.getTxnType(),
                    MoneyUtil.formatMoney(t.getAmountPaise()),
                    MoneyUtil.formatMoney(Math.max(0, running)),
                    t.getReference() == null ? "" : t.getReference()
            ));
        }

        return sb.toString();
    }

    private String makeSafeFileName(String s) {
        if (s == null) return "export";
        return s.replaceAll("[\\\\/:*?\"<>|]", "_").trim();
    }
}
