package com.gasstation.app.dao;

import com.gasstation.app.db.Db;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SettingsDaoTest {

    @TempDir
    Path tempDir;

    private Path testDbPath;
    private SettingsDao settingsDao;

    @BeforeEach
    void setUp() throws Exception {
        testDbPath = tempDir.resolve("settings-dao-test.db");
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
    void dbInitCreatesDefaultSettingsAndBackupTable() throws Exception {
        assertEquals("0.18", settingsDao.get("interest_annual_rate", "missing"));
        assertEquals("0", settingsDao.get("interest_grace_days", "missing"));

        try (Connection conn = Db.getConnection(); Statement st = conn.createStatement()) {
            try (ResultSet rs = st.executeQuery("SELECT COUNT(*) FROM backups")) {
                assertTrue(rs.next());
                assertEquals(0, rs.getInt(1));
            }
        }
    }

    @Test
    void setGetAndTypedFallbacksWork() throws Exception {
        settingsDao.set("sample_int", "42");
        settingsDao.set("sample_double", "3.25");
        settingsDao.set("bad_int", "oops");
        settingsDao.set("bad_double", "oops");

        assertEquals("42", settingsDao.get("sample_int", "fallback"));
        assertEquals(42, settingsDao.getInt("sample_int", 7));
        assertEquals(7, settingsDao.getInt("bad_int", 7));
        assertEquals(3.25, settingsDao.getDouble("sample_double", 1.5));
        assertEquals(1.5, settingsDao.getDouble("bad_double", 1.5));
        assertEquals("fallback", settingsDao.get("missing", "fallback"));
    }
}
