package com.gasstation.app.db;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;

public final class Db {

    private static final String APP_DIR = ".credit-accounting";
    private static final String DB_FILE = "credit.db";

    private Db() {}

    public static Connection connect() throws SQLException {
        // Force-load SQLite JDBC driver (helps in packaging / classpath edge cases)
        try {
            Class.forName("org.sqlite.JDBC");
        } catch (ClassNotFoundException e) {
            throw new SQLException("SQLite JDBC driver missing (org.sqlite.JDBC). Check classpath.", e);
        }

        return DriverManager.getConnection("jdbc:sqlite:" + getDbPath().toAbsolutePath());
    }


    // Alias for DAOs
    public static Connection getConnection() throws SQLException {
        return connect();
    }

    public static void init() {
        try {
            Files.createDirectories(getDbDir());
        } catch (IOException e) {
            throw new RuntimeException("Failed to create app data directory", e);
        }

        try (Connection conn = connect(); Statement st = conn.createStatement()) {

            st.execute("PRAGMA foreign_keys = ON;");

            /* =========================
               CUSTOMERS
               ========================= */
            st.execute("""
                CREATE TABLE IF NOT EXISTS customers (
                    customer_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    phone TEXT NOT NULL UNIQUE,
                    address TEXT,
                    notes TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
            """);

            // Safe migrations
            try { st.execute("ALTER TABLE customers ADD COLUMN credit_limit_paise INTEGER NOT NULL DEFAULT 0;"); }
            catch (SQLException ignored) {}
            try { st.execute("ALTER TABLE customers ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1;"); }
            catch (SQLException ignored) {}

            // Business metrics / collections fields
            try { st.execute("ALTER TABLE customers ADD COLUMN due_days INTEGER NOT NULL DEFAULT 30;"); }
            catch (SQLException ignored) {}
            try { st.execute("ALTER TABLE customers ADD COLUMN grace_days INTEGER NOT NULL DEFAULT 0;"); }
            catch (SQLException ignored) {}
            try { st.execute("ALTER TABLE customers ADD COLUMN risk_score INTEGER NOT NULL DEFAULT 0;"); }
            catch (SQLException ignored) {}
            try { st.execute("ALTER TABLE customers ADD COLUMN risk_level TEXT NOT NULL DEFAULT 'LOW';"); }
            catch (SQLException ignored) {}
            try { st.execute("ALTER TABLE customers ADD COLUMN next_followup_date TEXT;"); }
            catch (SQLException ignored) {}
            try { st.execute("ALTER TABLE customers ADD COLUMN followup_notes TEXT;"); }
            catch (SQLException ignored) {}

            // Fast lookups
            st.execute("CREATE INDEX IF NOT EXISTS idx_customers_phone ON customers(phone);");
            st.execute("CREATE INDEX IF NOT EXISTS idx_customers_name ON customers(name);");

            /* =========================
               PHONE HISTORY
               ========================= */
            st.execute("""
                CREATE TABLE IF NOT EXISTS customer_phone_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    customer_id INTEGER NOT NULL,
                    old_phone TEXT,
                    new_phone TEXT NOT NULL,
                    changed_at TEXT NOT NULL DEFAULT (datetime('now')),
                    changed_by TEXT,
                    note TEXT,
                    FOREIGN KEY(customer_id) REFERENCES customers(customer_id)
                        ON DELETE CASCADE ON UPDATE CASCADE
                );
            """);

            st.execute("""
                CREATE INDEX IF NOT EXISTS idx_phone_hist_customer
                ON customer_phone_history(customer_id, changed_at);
            """);

            /* =========================
               TRANSACTIONS
               ========================= */
            st.execute("""
                CREATE TABLE IF NOT EXISTS transactions (
                    txn_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    customer_id INTEGER NOT NULL,
                    txn_date TEXT NOT NULL,
                    txn_type TEXT NOT NULL CHECK (txn_type IN ('DEBIT','CREDIT')),
                    amount_paise INTEGER NOT NULL CHECK (amount_paise > 0),
                    reference TEXT,
                    notes TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
                        ON DELETE RESTRICT ON UPDATE CASCADE
                );
            """);

            st.execute("CREATE INDEX IF NOT EXISTS idx_transactions_customer_date ON transactions(customer_id, txn_date);");
            st.execute("CREATE INDEX IF NOT EXISTS idx_transactions_type_date ON transactions(txn_type, txn_date);");

            // Transaction status (voiding instead of deleting)
            try { st.execute("ALTER TABLE transactions ADD COLUMN status TEXT NOT NULL DEFAULT 'POSTED';"); }
            catch (SQLException ignored) {}
            try { st.execute("ALTER TABLE transactions ADD COLUMN void_reason TEXT;"); }
            catch (SQLException ignored) {}
            try { st.execute("ALTER TABLE transactions ADD COLUMN voided_at TEXT;"); }
            catch (SQLException ignored) {}

            /* =========================
               APP SETTINGS
               ========================= */
            st.execute("""
                CREATE TABLE IF NOT EXISTS app_settings (
                    setting_key TEXT PRIMARY KEY,
                    setting_value TEXT NOT NULL,
                    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
            """);

            st.execute("INSERT OR IGNORE INTO app_settings(setting_key, setting_value) VALUES('interest_annual_rate', '0.18');");
            st.execute("INSERT OR IGNORE INTO app_settings(setting_key, setting_value) VALUES('interest_grace_days', '0');");

            /* =========================
               REMINDERS (collections)
               ========================= */
            st.execute("""
                CREATE TABLE IF NOT EXISTS reminders (
                    reminder_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    customer_id INTEGER NOT NULL,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    due_date TEXT,
                    days_past_due INTEGER NOT NULL DEFAULT 0,
                    amount_paise INTEGER NOT NULL DEFAULT 0,
                    template_key TEXT NOT NULL,
                    message_text TEXT NOT NULL,
                    channel TEXT NOT NULL,
                    sent_status TEXT NOT NULL DEFAULT 'SENT',
                    sent_by TEXT,
                    FOREIGN KEY(customer_id) REFERENCES customers(customer_id)
                        ON DELETE CASCADE ON UPDATE CASCADE
                );
            """);
            st.execute("CREATE INDEX IF NOT EXISTS idx_reminders_customer ON reminders(customer_id, created_at);");

            /* =========================
               AUDIT LOG (accountability)
               ========================= */
            st.execute("""
                CREATE TABLE IF NOT EXISTS audit_log (
                    audit_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    user_id INTEGER,
                    action TEXT NOT NULL,
                    entity TEXT NOT NULL,
                    entity_id INTEGER,
                    details TEXT
                );
            """);
            st.execute("CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_log(entity, entity_id, created_at);");

            /* =========================
               BACKUPS (optional metadata)
               ========================= */
            st.execute("""
                CREATE TABLE IF NOT EXISTS backups (
                    backup_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    file_path TEXT NOT NULL,
                    created_by TEXT
                );
            """);

        } catch (SQLException e) {
            throw new RuntimeException("DB init failed", e);
        }
    }

    private static Path getDbDir() {
        return Path.of(System.getProperty("user.home"), APP_DIR);
    }

    private static Path getDbPath() {
        return getDbDir().resolve(DB_FILE);
    }
}
