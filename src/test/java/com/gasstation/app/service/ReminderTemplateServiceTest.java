package com.gasstation.app.service;

import com.gasstation.app.dao.SettingsDao;
import com.gasstation.app.db.Db;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.CustomerKpi;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ReminderTemplateServiceTest {

    @TempDir
    Path tempDir;

    private SettingsDao settingsDao;
    private Path testDbPath;

    @BeforeEach
    void setUp() throws Exception {
        testDbPath = tempDir.resolve("credit-accounting-reminder-test.db");
        System.setProperty(Db.DB_PATH_PROPERTY, testDbPath.toString());
        Db.init();
        settingsDao = new SettingsDao();
    }

    @AfterEach
    void tearDown() throws Exception {
        System.clearProperty(Db.DB_PATH_PROPERTY);
        Files.deleteIfExists(testDbPath);
    }

    @Test
    void rendersEnglishTemplatePlaceholdersAndLeavesUnknownPlaceholdersUnchanged() throws Exception {
        settingsDao.set(ReminderTemplateService.KEY_TPL_OVERDUE_EN,
                "Hi {NAME}, pay {AMOUNT} of {TOTAL}; {DAYS} days overdue. {UNKNOWN}");
        settingsDao.set(ReminderTemplateService.KEY_BUSINESS_NAME, "Fuel Station");
        settingsDao.set(ReminderTemplateService.KEY_BUSINESS_CONTACT, "99999");

        String message = new ReminderTemplateService().render(
                ReminderTemplateService.TemplateKey.OVERDUE,
                ReminderTemplateService.Lang.EN,
                kpi("Ravi", 12_345L, 20_000L, 10));

        assertTrue(message.contains("Ravi"));
        assertTrue(message.contains("₹123.45"));
        assertTrue(message.contains("₹200.00"));
        assertTrue(message.contains("10 days overdue"));
        assertTrue(message.contains("{UNKNOWN}"));
    }

    @Test
    void rendersTeluguFallbackTemplatePlaceholders() {
        String message = new ReminderTemplateService().render(
                ReminderTemplateService.TemplateKey.OVERDUE,
                ReminderTemplateService.Lang.TE,
                kpi("రవి", 12_345L, 20_000L, 10));

        assertTrue(message.contains("రవి"));
        assertTrue(message.contains("₹123.45"));
        assertTrue(message.contains("10"));
    }

    @Test
    void autoPicksReminderTemplateFromConfiguredThresholds() throws Exception {
        settingsDao.set(ReminderTemplateService.KEY_AUTO_GENTLE_MAX_DAYS, "5");
        settingsDao.set(ReminderTemplateService.KEY_AUTO_OVERDUE_MAX_DAYS, "20");

        ReminderTemplateService service = new ReminderTemplateService();

        assertEquals(ReminderTemplateService.TemplateKey.GENTLE, service.autoPick(5));
        assertEquals(ReminderTemplateService.TemplateKey.OVERDUE, service.autoPick(6));
        assertEquals(ReminderTemplateService.TemplateKey.OVERDUE, service.autoPick(20));
        assertEquals(ReminderTemplateService.TemplateKey.FINAL, service.autoPick(21));
    }

    @Test
    void returnsEmptyStringForMissingKpiOrCustomer() {
        ReminderTemplateService service = new ReminderTemplateService();

        assertEquals("", service.render(ReminderTemplateService.TemplateKey.GENTLE, ReminderTemplateService.Lang.EN, null));
        assertEquals("", service.render(ReminderTemplateService.TemplateKey.GENTLE, ReminderTemplateService.Lang.EN, new CustomerKpi()));
    }

    private static CustomerKpi kpi(String name, long overduePaise, long totalPaise, int daysOverdue) {
        Customer customer = new Customer();
        customer.setName(name);

        CustomerKpi kpi = new CustomerKpi();
        kpi.setCustomer(customer);
        kpi.setOverdueAmountPaise(overduePaise);
        kpi.setTotalDuePaise(totalPaise);
        kpi.setMaxDaysOverdue(daysOverdue);
        return kpi;
    }
}
