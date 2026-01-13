package com.gasstation.app.service;

import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.model.Transaction;

import java.nio.file.Path;
import java.time.LocalDate;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;

/**
 * Backward-compatible wrapper used by ReportsScreen.
 *
 * Exports a single "full ledger" Excel file including:
 * - Customers sheet (with hyperlinks)
 * - All_Transactions sheet
 * - One sheet per customer
 *
 * IMPORTANT: TransactionDao.listAllPosted() excludes VOID, so VOID never appears.
 */
public class LedgerExportService {

    private final TransactionDao txnDao;
    private final LedgerExcelExportService excelSvc;

    public LedgerExportService() {
        this(new TransactionDao(), new LedgerExcelExportService());
    }

    public LedgerExportService(TransactionDao txnDao, LedgerExcelExportService excelSvc) {
        this.txnDao = Objects.requireNonNull(txnDao);
        this.excelSvc = Objects.requireNonNull(excelSvc);
    }

    /**
     * ReportsScreen expects this signature.
     * Exports FULL history (earliest posted txn -> today). If there are no transactions,
     * it exports today->today (empty transaction sheets, but customers still included).
     */
    public void exportAllCustomersWithLedgers(Path outFile) throws Exception {
        Objects.requireNonNull(outFile, "outFile");

        List<Transaction> all = txnDao.listAllPosted(); // VOID excluded ✅

        LocalDate from;
        LocalDate to = LocalDate.now();

        if (all.isEmpty()) {
            from = to;
        } else {
            from = all.stream()
                    .map(t -> LocalDate.parse(t.getTxnDate()))
                    .min(Comparator.naturalOrder())
                    .orElse(to);
        }

        excelSvc.exportAccountingXlsx(outFile, from, to);
    }
}
