package com.gasstation.app.service;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.SettingsDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.db.Db;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.CustomerKpi;
import com.gasstation.app.model.Transaction;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class CustomerKpiServiceTest {

    @TempDir
    Path tempDir;

    private CustomerDao customerDao;
    private TransactionDao transactionDao;
    private SettingsDao settingsDao;
    private Path testDbPath;

    @BeforeEach
    void setUp() throws Exception {
        testDbPath = tempDir.resolve("credit-accounting-kpi-test.db");
        System.setProperty(Db.DB_PATH_PROPERTY, testDbPath.toString());
        Db.init();
        customerDao = new CustomerDao();
        transactionDao = new TransactionDao();
        settingsDao = new SettingsDao();
        settingsDao.set(CustomerKpiService.KEY_RATE, "0.18");
    }

    @AfterEach
    void tearDown() throws Exception {
        System.clearProperty(Db.DB_PATH_PROPERTY);
        Files.deleteIfExists(testDbPath);
    }

    @Test
    void computesPrincipalOverdueGraceDaysAndYellowRiskFromPostedTransactions() throws Exception {
        LocalDate today = LocalDate.now();
        Customer customer = new Customer("KPI Customer", "9999991001", null, null);
        customer.setDueDays(10);
        customer.setGraceDays(2);
        long customerId = customerDao.insert(customer);
        customer.setCustomerId(customerId);

        transactionDao.insert(txn(customerId, today.minusDays(20), "DEBIT", 100_000L));
        transactionDao.insert(txn(customerId, today.minusDays(15), "CREDIT", 30_000L));
        transactionDao.insert(txn(customerId, today.minusDays(5), "DEBIT", 50_000L));

        CustomerKpi kpi = new CustomerKpiService().buildForCustomer(customer);

        assertEquals(120_000L, kpi.getPrincipalBalancePaise());
        assertEquals(120_000L + kpi.getInterestAccruedPaise(), kpi.getTotalDuePaise());
        assertTrue(kpi.getInterestAccruedPaise() > 0, "interest should accrue on outstanding principal");
        assertEquals(70_000L, kpi.getOverdueAmountPaise());
        assertEquals(10, kpi.getMaxDaysOverdue());
        assertEquals(today.minusDays(15), kpi.getLastPaymentDate());
        assertEquals(1, kpi.getPaymentsLast30Days());
        assertEquals(50, kpi.getRiskScore());
        assertEquals("YELLOW", kpi.getRiskTag());
    }

    @Test
    void regularRecentPaymentsCanKeepRiskGreenWhenNoOverdueBalanceExists() throws Exception {
        LocalDate today = LocalDate.now();
        Customer customer = new Customer("Green Customer", "9999991002", null, null);
        customer.setDueDays(30);
        customer.setGraceDays(0);
        long customerId = customerDao.insert(customer);
        customer.setCustomerId(customerId);

        transactionDao.insert(txn(customerId, today.minusDays(5), "DEBIT", 50_000L));
        transactionDao.insert(txn(customerId, today.minusDays(4), "CREDIT", 10_000L));
        transactionDao.insert(txn(customerId, today.minusDays(2), "CREDIT", 10_000L));

        CustomerKpi kpi = new CustomerKpiService().buildForCustomer(customer);

        assertEquals(30_000L, kpi.getPrincipalBalancePaise());
        assertEquals(0L, kpi.getOverdueAmountPaise());
        assertEquals(0, kpi.getMaxDaysOverdue());
        assertEquals(2, kpi.getPaymentsLast30Days());
        assertEquals(0, kpi.getRiskScore());
        assertEquals("GREEN", kpi.getRiskTag());
    }

    private static Transaction txn(long customerId, LocalDate date, String type, long amountPaise) {
        Transaction txn = new Transaction();
        txn.setCustomerId(customerId);
        txn.setTxnDate(date.toString());
        txn.setTxnType(type);
        txn.setAmountPaise(amountPaise);
        return txn;
    }
}
