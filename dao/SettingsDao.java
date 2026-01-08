package com.gasstation.app.dao;

import com.gasstation.app.db.Db;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;

/**
 * Simple key/value settings table.
 * We use this for business knobs like interest rate and grace days.
 */
public class SettingsDao {

    public String get(String key, String defaultValue) throws SQLException {
        String sql = "SELECT setting_value FROM app_settings WHERE setting_key = ?;";
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, key);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) return rs.getString(1);
            }
        }
        return defaultValue;
    }

    public void set(String key, String value) throws SQLException {
        String sql = """
            INSERT INTO app_settings(setting_key, setting_value, updated_at)
            VALUES(?, ?, datetime('now'))
            ON CONFLICT(setting_key) DO UPDATE SET
                setting_value = excluded.setting_value,
                updated_at = datetime('now');
        """;

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setString(1, key);
            ps.setString(2, value);
            ps.executeUpdate();
        }
    }

    public double getDouble(String key, double defaultValue) throws SQLException {
        String v = get(key, Double.toString(defaultValue));
        try {
            return Double.parseDouble(v.trim());
        } catch (Exception e) {
            return defaultValue;
        }
    }

    public int getInt(String key, int defaultValue) throws SQLException {
        String v = get(key, Integer.toString(defaultValue));
        try {
            return Integer.parseInt(v.trim());
        } catch (Exception e) {
            return defaultValue;
        }
    }
}
