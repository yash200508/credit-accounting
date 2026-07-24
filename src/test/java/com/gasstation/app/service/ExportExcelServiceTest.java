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

import java.io.File;
import java.io.FileInputStream;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ExportExcelServiceTest {

    @TempDir
    Path tempDir;

    private Path testDbPath;
    private CustomerDao customerDao;
    private TransactionDao transactionDao;

    @BeforeEach
    void setUp() throws Exception {
        testDbPath = tempDir.resolve("export-excel-test.db");
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
    void exportsCustomersAndOnlyPostedTransactionsToWorkbook() throws Exception {
        long customerId = customerDao.insert(new Customer("Export Customer", "9999994001", "Addr", "Notes"));
        long postedTxnId = transactionDao.insert(txn(customerId, "2026-01-01", "DEBIT", 12_345L));
        long voidTxnId = transactionDao.insert(txn(customerId, "2026-01-02", "DEBIT", 99_999L));
        transactionDao.voidTransaction(voidTxnId, "Wrong row");

        File outFile = tempDir.resolve("export.xlsx").toFile();
        new ExportExcelService(customerDao, transactionDao).exportAllToXlsx(outFile);

        assertTrue(outFile.isFile());
        try (Workbook wb = new XSSFWorkbook(new FileInputStream(outFile))) {
            Sheet customers = wb.getSheet("Customers");
            Sheet transactions = wb.getSheet("Transactions");

            assertNotNull(customers);
            assertNotNull(transactions);
            assertEquals("customer_id", customers.getRow(0).getCell(0).getStringCellValue());
            assertEquals("Export Customer", customers.getRow(1).getCell(1).getStringCellValue());
            assertEquals("9999994001", customers.getRow(1).getCell(2).getStringCellValue());

            assertEquals(1, transactions.getLastRowNum(),
                    "Transactions sheet should include header + one posted transaction");
            assertEquals(postedTxnId, (long) transactions.getRow(1).getCell(0).getNumericCellValue());
            assertEquals(customerId, (long) transactions.getRow(1).getCell(1).getNumericCellValue());
            assertEquals("Export Customer", transactions.getRow(1).getCell(2).getStringCellValue());
            assertEquals(12_345L, (long) transactions.getRow(1).getCell(6).getNumericCellValue());
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
