package com.gasstation.app.dao;

import com.gasstation.app.db.Db;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.Transaction;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class TransactionDaoTest {

    @TempDir
    Path tempDir;

    private CustomerDao customerDao;
    private TransactionDao transactionDao;
    private Path testDbPath;

    @BeforeEach
    void setUp() throws Exception {
        testDbPath = tempDir.resolve("credit-accounting-test.db");
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
    void insertedPostedTransactionsAppearInLedgerAndPostedLists() throws Exception {
        long customerId = insertCustomer("Posted Customer", "9999990001");
        long txnId = transactionDao.insert(txn(customerId, "2026-01-01", "DEBIT", 12_345L, "fuel", "posted"));

        List<Transaction> ledger = transactionDao.listByCustomer(customerId);
        List<Transaction> posted = transactionDao.listAllPosted();

        assertEquals(1, ledger.size());
        assertEquals(txnId, ledger.get(0).getTxnId());
        assertEquals("POSTED", ledger.get(0).getStatus());
        assertEquals(1, posted.size());
        assertEquals(txnId, posted.get(0).getTxnId());
    }

    @Test
    void voidedTransactionsAreExcludedButVoidMetadataIsPreserved() throws Exception {
        long customerId = insertCustomer("Void Customer", "9999990002");
        long postedTxnId = transactionDao.insert(txn(customerId, "2026-01-01", "DEBIT", 10_000L, "fuel", "posted"));
        long voidTxnId = transactionDao.insert(txn(customerId, "2026-01-02", "DEBIT", 20_000L, "mistake", "void me"));

        transactionDao.voidTransaction(voidTxnId, "Wrong customer");

        List<Transaction> ledger = transactionDao.listByCustomer(customerId);
        List<Transaction> posted = transactionDao.listAllPosted();

        assertEquals(1, ledger.size());
        assertEquals(postedTxnId, ledger.get(0).getTxnId());
        assertEquals(1, posted.size());
        assertEquals(postedTxnId, posted.get(0).getTxnId());

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement("SELECT status, void_reason, voided_at FROM transactions WHERE txn_id = ?")) {
            ps.setLong(1, voidTxnId);
            try (ResultSet rs = ps.executeQuery()) {
                assertTrue(rs.next(), "voided transaction row should still exist");
                assertEquals("VOID", rs.getString("status"));
                assertEquals("Wrong customer", rs.getString("void_reason"));
                assertNotNull(rs.getString("voided_at"));
            }
        }
    }

    @Test
    void sumsExcludeVoidedTransactions() throws Exception {
        long customerId = insertCustomer("Sum Customer", "9999990003");
        long voidTxnId = transactionDao.insert(txn(customerId, "2026-01-01", "DEBIT", 20_000L, "mistake", "void"));
        transactionDao.insert(txn(customerId, "2026-01-02", "DEBIT", 10_000L, "fuel", "posted"));
        transactionDao.insert(txn(customerId, "2026-01-03", "CREDIT", 3_000L, "payment", "posted"));
        transactionDao.voidTransaction(voidTxnId, "Correction");

        assertEquals(10_000L, transactionDao.sumByTypeBetween(customerId, "DEBIT", "2026-01-01", "2026-01-31"));
        assertEquals(3_000L, transactionDao.sumByTypeBetween(customerId, "CREDIT", "2026-01-01", "2026-01-31"));
        assertEquals(10_000L, transactionDao.sumAllByTypeBetween("DEBIT", "2026-01-01", "2026-01-31"));
    }

    private long insertCustomer(String name, String phone) throws Exception {
        Customer customer = new Customer(name, phone, null, null);
        customer.setDueDays(30);
        customer.setGraceDays(0);
        return customerDao.insert(customer);
    }

    private static Transaction txn(long customerId, String date, String type, long amountPaise, String reference, String notes) {
        Transaction txn = new Transaction();
        txn.setCustomerId(customerId);
        txn.setTxnDate(date);
        txn.setTxnType(type);
        txn.setAmountPaise(amountPaise);
        txn.setReference(reference);
        txn.setNotes(notes);
        return txn;
    }
}
