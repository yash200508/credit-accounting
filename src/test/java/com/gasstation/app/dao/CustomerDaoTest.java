package com.gasstation.app.dao;

import com.gasstation.app.db.Db;
import com.gasstation.app.model.Customer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

class CustomerDaoTest {

    @TempDir
    Path tempDir;

    private Path testDbPath;
    private CustomerDao customerDao;

    @BeforeEach
    void setUp() throws Exception {
        testDbPath = tempDir.resolve("customer-dao-test.db");
        System.setProperty(Db.DB_PATH_PROPERTY, testDbPath.toString());
        Db.init();
        customerDao = new CustomerDao();
    }

    @AfterEach
    void tearDown() throws Exception {
        System.clearProperty(Db.DB_PATH_PROPERTY);
        Files.deleteIfExists(testDbPath);
    }

    @Test
    void persistsActiveStatusAndCreditPolicyFields() throws Exception {
        Customer customer = new Customer("Policy Customer", "9999993001", "Addr", "Notes", 0);
        customer.setCreditLimitPaise(250_000L);
        customer.setDueDays(20);
        customer.setGraceDays(4);

        long id = customerDao.insert(customer);
        Customer saved = customerDao.findByPhone("9999993001");

        assertNotNull(saved);
        assertEquals(id, saved.getCustomerId());
        assertEquals(0, saved.getIsActive());
        assertEquals(250_000L, saved.getCreditLimitPaise());
        assertEquals(20, saved.getDueDays());
        assertEquals(4, saved.getGraceDays());
        assertEquals(1, customerDao.countAllCustomers(true));
        assertEquals(0, customerDao.countAllCustomers(false));
    }

    @Test
    void activeFlagCanBeChangedAndAffectsActiveCounts() throws Exception {
        long id = customerDao.insert(new Customer("Active Customer", "9999993002", null, null));

        assertEquals(1, customerDao.countAllCustomers(false));
        customerDao.setCustomerActive(id, false);
        assertEquals(0, customerDao.countAllCustomers(false));
        assertEquals(1, customerDao.countAllCustomers(true));
    }

    @Test
    void phoneUpdateNormalizesPhoneAndWritesHistory() throws Exception {
        long id = customerDao.insert(new Customer("Phone Customer", "9999993003", null, null));

        customerDao.updateCustomerPhone(id, "+91 88888 83003", "tester", "new card");

        Customer updated = customerDao.findByPhone("8888883003");
        assertNotNull(updated);
        assertEquals(id, updated.getCustomerId());

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement("SELECT old_phone, new_phone, changed_by, note FROM customer_phone_history WHERE customer_id = ?")) {
            ps.setLong(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                assertEquals(true, rs.next());
                assertEquals("9999993003", rs.getString("old_phone"));
                assertEquals("8888883003", rs.getString("new_phone"));
                assertEquals("tester", rs.getString("changed_by"));
                assertEquals("new card", rs.getString("note"));
            }
        }
    }

    @Test
    void invalidPhoneUpdateIsRejected() throws Exception {
        long id = customerDao.insert(new Customer("Invalid Phone Customer", "9999993004", null, null));

        assertThrows(IllegalArgumentException.class, () -> customerDao.updateCustomerPhone(id, "12345", "tester", "bad"));
    }
}
