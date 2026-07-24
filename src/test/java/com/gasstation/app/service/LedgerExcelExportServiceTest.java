package com.gasstation.app.service;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.db.Db;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.Transaction;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.FileInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LedgerExcelExportServiceTest {

    @TempDir
    Path tempDir;

    private Path testDbPath;
    private CustomerDao customerDao;
    private TransactionDao transactionDao;

    @BeforeEach
    void setUp() throws Exception {
        testDbPath = tempDir.resolve("ledger-excel-test.db");
        System.setProperty(Db.DB_PATH_PROPERTY, testDbPath.toString());
        Db.init();
        customerDao = new CustomerDao();
        transactionDao = new TransactionDao();
    }

    @AfterEach
    void tearDown() throws Exception {
        System.clearProperty(Db.DB_PATH_PROPERTY);
        Files.deleteIfExists(testDbPath);
    }

    @Test
    void accountingExportIncludesRangePostedTransactionsAndCustomerLedgerSheets() throws Exception {
        long customerId = customerDao.insert(new Customer("Ledger Customer", "9999995001", null, null));
        transactionDao.insert(txn(customerId, "2026-01-01", "DEBIT", 10_000L));
        transactionDao.insert(txn(customerId, "2026-02-01", "CREDIT", 5_000L));
        long voidTxnId = transactionDao.insert(txn(customerId, "2026-01-10", "DEBIT", 99_999L));
        transactionDao.voidTransaction(voidTxnId, "Correction");

        Path outFile = tempDir.resolve("accounting.xlsx");
        new LedgerExcelExportService().exportAccountingXlsx(outFile, LocalDate.parse("2026-01-01"), LocalDate.parse("2026-01-31"));

        assertTrue(Files.isRegularFile(outFile));
        try (Workbook wb = new XSSFWorkbook(new FileInputStream(outFile.toFile()))) {
            Sheet customers = wb.getSheet("Customers");
            Sheet allTransactions = wb.getSheet("All_Transactions");
            Sheet customerLedger = wb.getSheet("Ledger Customer");

            assertNotNull(customers);
            assertNotNull(allTransactions);
            assertNotNull(customerLedger);
            assertEquals("Ledger Customer", customers.getRow(1).getCell(1).getStringCellValue());
            assertNotNull(customers.getRow(1).getCell(1).getHyperlink());

            assertEquals(1, allTransactions.getLastRowNum(),
                    "All_Transactions should include header + January posted transaction only");
            assertEquals(customerId, (long) allTransactions.getRow(1).getCell(1).getNumericCellValue());
            assertEquals("2026-01-01", allTransactions.getRow(1).getCell(2).getStringCellValue());
            assertEquals(10_000L, (long) allTransactions.getRow(1).getCell(4).getNumericCellValue());

            assertEquals(1, customerLedger.getLastRowNum(),
                    "Customer ledger sheet should include header + January posted transaction only");
            assertEquals("2026-01-01", customerLedger.getRow(1).getCell(1).getStringCellValue());
            assertEquals(10_000L, (long) customerLedger.getRow(1).getCell(3).getNumericCellValue());
        }
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
