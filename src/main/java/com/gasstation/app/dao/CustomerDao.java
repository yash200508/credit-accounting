package com.gasstation.app.dao;

import com.gasstation.app.db.Db;
import com.gasstation.app.model.Customer;

import java.sql.*;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class CustomerDao {

    /* =========================
       CREATE
       ========================= */

    public long insert(Customer c) throws SQLException {
        String sql = """
            INSERT INTO customers(
                name, phone, address, notes,
                is_active, credit_limit_paise, due_days, grace_days
            )
            VALUES(?,?,?,?,?,?,?,?);
        """;

        String name = (c.getName() == null) ? "" : c.getName().trim();
        if (name.isEmpty()) throw new SQLException("Name is required");

        String phone = normalizePhone(c.getPhone());
        if (phone.isEmpty()) throw new SQLException("Phone must have 10 digits");

        int isActive = (c.getIsActive() == 0) ? 0 : 1;

        long creditLimit = Math.max(0, c.getCreditLimitPaise());

        // default dueDays to 30 if 0
        int dueDays = c.getDueDays();
        if (dueDays <= 0) dueDays = 30;

        int graceDays = Math.max(0, c.getGraceDays());

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql, Statement.RETURN_GENERATED_KEYS)) {

            ps.setString(1, name);
            ps.setString(2, phone);
            ps.setString(3, emptyToNull(c.getAddress()));
            ps.setString(4, emptyToNull(c.getNotes()));
            ps.setInt(5, isActive);
            ps.setLong(6, creditLimit);
            ps.setInt(7, dueDays);
            ps.setInt(8, graceDays);

            ps.executeUpdate();

            try (ResultSet rs = ps.getGeneratedKeys()) {
                if (rs.next()) return rs.getLong(1);
            }
        }

        throw new SQLException("Insert failed");
    }

    /* =========================
       READ
       ========================= */

    public Customer findByPhone(String phone) throws SQLException {
        String p = normalizePhone(phone);
        if (p.isEmpty()) return null;

        String sql = """
            SELECT customer_id, name, phone, address, notes, is_active,
                   credit_limit_paise, due_days, grace_days,
                   risk_score, risk_level, next_followup_date, followup_notes
            FROM customers
            WHERE phone = ?;
        """;

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, p);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? map(rs) : null;
            }
        }
    }

    public List<Customer> listAll() throws SQLException {
        String sql = """
            SELECT customer_id, name, phone, address, notes, is_active,
                   credit_limit_paise, due_days, grace_days,
                   risk_score, risk_level, next_followup_date, followup_notes
            FROM customers
            ORDER BY name;
        """;

        List<Customer> list = new ArrayList<>();
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql);
             ResultSet rs = ps.executeQuery()) {

            while (rs.next()) list.add(map(rs));
        }
        return list;
    }

    public List<Customer> searchByNameOrPhone(String q, int limit) throws SQLException {
        if (q == null || q.trim().isEmpty()) return Collections.emptyList();

        String like = "%" + q.toLowerCase().trim() + "%";
        String phoneLike = "%" + digitsOnly(q) + "%";

        String sql = """
            SELECT customer_id, name, phone, address, notes, is_active,
                   credit_limit_paise, due_days, grace_days,
                   risk_score, risk_level, next_followup_date, followup_notes
            FROM customers
            WHERE lower(name) LIKE ?
               OR phone LIKE ?
            ORDER BY name
            LIMIT ?;
        """;

        List<Customer> list = new ArrayList<>();
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, like);
            ps.setString(2, phoneLike);
            ps.setInt(3, Math.max(1, limit));

            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) list.add(map(rs));
            }
        }
        return list;
    }

    /* =========================
       SEARCH (paged) — REQUIRED by CustomerScreen ✅
       ========================= */

    public int countByNameOrPhone(String q, boolean includeInactive) throws SQLException {
        String term = (q == null) ? "" : q.trim();
        if (term.isEmpty()) return 0;

        String like = "%" + term.toLowerCase() + "%";
        String phoneLike = "%" + digitsOnly(term) + "%";

        String sql = includeInactive
                ? "SELECT COUNT(*) AS c FROM customers WHERE lower(name) LIKE ? OR phone LIKE ?;"
                : "SELECT COUNT(*) AS c FROM customers WHERE (lower(name) LIKE ? OR phone LIKE ?) AND is_active = 1;";

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, like);
            ps.setString(2, phoneLike);

            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getInt("c") : 0;
            }
        }
    }

    public List<Customer> searchPageByNameOrPhone(String q, int limit, int offset, boolean includeInactive) throws SQLException {
        String term = (q == null) ? "" : q.trim();
        if (term.isEmpty()) return Collections.emptyList();

        String like = "%" + term.toLowerCase() + "%";
        String phoneLike = "%" + digitsOnly(term) + "%";

        String sql = includeInactive
                ? """
                    SELECT customer_id, name, phone, address, notes, is_active,
                           credit_limit_paise, due_days, grace_days,
                           risk_score, risk_level, next_followup_date, followup_notes
                    FROM customers
                    WHERE lower(name) LIKE ? OR phone LIKE ?
                    ORDER BY name
                    LIMIT ? OFFSET ?;
                  """
                : """
                    SELECT customer_id, name, phone, address, notes, is_active,
                           credit_limit_paise, due_days, grace_days,
                           risk_score, risk_level, next_followup_date, followup_notes
                    FROM customers
                    WHERE (lower(name) LIKE ? OR phone LIKE ?) AND is_active = 1
                    ORDER BY name
                    LIMIT ? OFFSET ?;
                  """;

        List<Customer> out = new ArrayList<>();
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, like);
            ps.setString(2, phoneLike);
            ps.setInt(3, Math.max(1, limit));
            ps.setInt(4, Math.max(0, offset));

            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) out.add(map(rs));
            }
        }
        return out;
    }

    public int countAllCustomers(boolean includeInactive) throws SQLException {
        String sql = includeInactive
                ? "SELECT COUNT(*) AS c FROM customers;"
                : "SELECT COUNT(*) AS c FROM customers WHERE is_active = 1;";

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql);
             ResultSet rs = ps.executeQuery()) {

            return rs.next() ? rs.getInt("c") : 0;
        }
    }

    public List<Customer> listPageAll(int limit, int offset, boolean includeInactive) throws SQLException {
        String sql = includeInactive
                ? """
                    SELECT customer_id, name, phone, address, notes, is_active,
                           credit_limit_paise, due_days, grace_days,
                           risk_score, risk_level, next_followup_date, followup_notes
                    FROM customers
                    ORDER BY name
                    LIMIT ? OFFSET ?;
                  """
                : """
                    SELECT customer_id, name, phone, address, notes, is_active,
                           credit_limit_paise, due_days, grace_days,
                           risk_score, risk_level, next_followup_date, followup_notes
                    FROM customers
                    WHERE is_active = 1
                    ORDER BY name
                    LIMIT ? OFFSET ?;
                  """;

        List<Customer> out = new ArrayList<>();
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setInt(1, Math.max(1, limit));
            ps.setInt(2, Math.max(0, offset));

            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) out.add(map(rs));
            }
        }
        return out;
    }

    /* =========================
       UPDATE BASIC
       ========================= */

    public void updateCustomerName(long customerId, String newName) throws SQLException {
        String nm = (newName == null) ? "" : newName.trim();
        if (nm.isEmpty()) throw new SQLException("Name required");

        String sql = "UPDATE customers SET name=? WHERE customer_id=?";
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, nm);
            ps.setLong(2, customerId);
            ps.executeUpdate();
        }
    }

    public void updateCustomerAddressNotes(long customerId, String address, String notes) {
        String sql = "UPDATE customers SET address=?, notes=? WHERE customer_id=?";
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, emptyToNull(address));
            ps.setString(2, emptyToNull(notes));
            ps.setLong(3, customerId);
            ps.executeUpdate();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    public void setCustomerActive(long customerId, boolean active) {
        String sql = "UPDATE customers SET is_active=? WHERE customer_id=?";
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setInt(1, active ? 1 : 0);
            ps.setLong(2, customerId);
            ps.executeUpdate();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    /* =========================
       UPDATE PHONE (logs history) — REQUIRED by CustomerScreen ✅
       ========================= */

    public void updateCustomerPhone(long customerId, String newPhone, String changedBy, String note) {
        String normalized = normalizePhone(newPhone);
        if (normalized.isEmpty()) throw new IllegalArgumentException("Phone must have 10 digits");

        String qOld = "SELECT phone FROM customers WHERE customer_id = ?";
        String qUpdate = "UPDATE customers SET phone = ? WHERE customer_id = ?";
        String qHist = """
            INSERT INTO customer_phone_history(customer_id, old_phone, new_phone, changed_by, note)
            VALUES(?,?,?,?,?);
        """;

        try (Connection conn = Db.getConnection()) {
            conn.setAutoCommit(false);

            String oldPhone;

            try (PreparedStatement ps = conn.prepareStatement(qOld)) {
                ps.setLong(1, customerId);
                try (ResultSet rs = ps.executeQuery()) {
                    if (!rs.next()) throw new SQLException("Customer not found");
                    oldPhone = rs.getString("phone");
                }
            }

            if (normalized.equals(oldPhone)) {
                conn.rollback();
                return;
            }

            try (PreparedStatement ps = conn.prepareStatement(qUpdate)) {
                ps.setString(1, normalized);
                ps.setLong(2, customerId);
                ps.executeUpdate();
            }

            try (PreparedStatement ps = conn.prepareStatement(qHist)) {
                ps.setLong(1, customerId);
                ps.setString(2, oldPhone);
                ps.setString(3, normalized);
                ps.setString(4, emptyToNull(changedBy));
                ps.setString(5, emptyToNull(note));
                ps.executeUpdate();
            }

            conn.commit();
        } catch (Exception e) {
            throw new RuntimeException("Failed to update phone number", e);
        }
    }

    /* =========================
       CREDIT / FOLLOW-UP
       ========================= */

    public void updateCreditPolicy(
            long customerId,
            long creditLimitPaise,
            int dueDays,
            int graceDays,
            String nextFollowupDate,
            String followupNotes
    ) {
        String sql = """
            UPDATE customers
            SET credit_limit_paise=?,
                due_days=?,
                grace_days=?,
                next_followup_date=?,
                followup_notes=?
            WHERE customer_id=?;
        """;

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setLong(1, Math.max(0, creditLimitPaise));
            ps.setInt(2, Math.max(0, dueDays));
            ps.setInt(3, Math.max(0, graceDays));
            ps.setString(4, emptyToNull(nextFollowupDate));
            ps.setString(5, emptyToNull(followupNotes));
            ps.setLong(6, customerId);

            ps.executeUpdate();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    public void updateFollowup(long customerId, String nextFollowupDateIso, String followupNotes) {
        String sql = """
            UPDATE customers
            SET next_followup_date=?, followup_notes=?
            WHERE customer_id=?;
        """;

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, emptyToNull(nextFollowupDateIso));
            ps.setString(2, emptyToNull(followupNotes));
            ps.setLong(3, customerId);
            ps.executeUpdate();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    /* =========================
       MAPPING + HELPERS
       ========================= */

    private Customer map(ResultSet rs) throws SQLException {
        Customer c = new Customer();
        c.setCustomerId(rs.getLong("customer_id"));
        c.setName(rs.getString("name"));
        c.setPhone(rs.getString("phone"));
        c.setAddress(rs.getString("address"));
        c.setNotes(rs.getString("notes"));

        c.setIsActive(rs.getInt("is_active"));
        c.setCreditLimitPaise(rs.getLong("credit_limit_paise"));
        c.setDueDays(rs.getInt("due_days"));
        c.setGraceDays(rs.getInt("grace_days"));

        c.setRiskScore(rs.getInt("risk_score"));
        c.setRiskLevel(rs.getString("risk_level"));
        c.setNextFollowupDate(rs.getString("next_followup_date"));
        c.setFollowupNotes(rs.getString("followup_notes"));

        return c;
    }

    // last 10 digits only
    private String normalizePhone(String phone) {
        String d = digitsOnly(phone);
        if (d.length() < 10) return "";
        if (d.length() > 10) d = d.substring(d.length() - 10);
        return d;
    }

    private String digitsOnly(String s) {
        return (s == null) ? "" : s.replaceAll("\\D+", "");
    }

    private String emptyToNull(String s) {
        if (s == null) return null;
        String t = s.trim();
        return t.isEmpty() ? null : t;
    }
}
