package com.gasstation.app.dao;

import com.gasstation.app.db.Db;
import com.gasstation.app.model.Transaction;

import java.sql.*;
import java.util.ArrayList;
import java.util.List;

public class TransactionDao {

    /* =========================
       CREATE
       ========================= */

    public long insert(Transaction t) throws SQLException {
        String sql = """
            INSERT INTO transactions(customer_id, txn_date, txn_type, amount_paise, reference, notes, status)
            VALUES(?, ?, ?, ?, ?, ?, ?);
        """;

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql, Statement.RETURN_GENERATED_KEYS)) {

            ps.setLong(1, t.getCustomerId());
            ps.setString(2, t.getTxnDate());
            ps.setString(3, t.getTxnType());
            ps.setLong(4, t.getAmountPaise());
            ps.setString(5, emptyToNull(t.getReference()));
            ps.setString(6, emptyToNull(t.getNotes()));
            ps.setString(7, (t.getStatus() == null || t.getStatus().trim().isEmpty()) ? "POSTED" : t.getStatus().trim());

            ps.executeUpdate();

            try (ResultSet rs = ps.getGeneratedKeys()) {
                if (rs.next()) return rs.getLong(1);
            }
            throw new SQLException("No generated key returned");
        }
    }

    /* =========================
       READ (Customer) — VOID excluded ✅
       ========================= */

    public List<Transaction> listByCustomer(long customerId) throws SQLException {
        String sql = """
            SELECT txn_id, customer_id, txn_date, txn_type, amount_paise, reference, notes,
                   status, void_reason, voided_at
            FROM transactions
            WHERE customer_id = ?
              AND status <> 'VOID'
            ORDER BY txn_date ASC, txn_id ASC;
        """;

        List<Transaction> out = new ArrayList<>();
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setLong(1, customerId);

            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) out.add(map(rs));
            }
        }
        return out;
    }

    /* =========================
       READ (All) — for exports — VOID excluded ✅
       ========================= */

    public List<Transaction> listAllPosted() throws SQLException {
        String sql = """
            SELECT txn_id, customer_id, txn_date, txn_type, amount_paise, reference, notes,
                   status, void_reason, voided_at
            FROM transactions
            WHERE status <> 'VOID'
            ORDER BY txn_date ASC, txn_id ASC;
        """;

        List<Transaction> out = new ArrayList<>();
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql);
             ResultSet rs = ps.executeQuery()) {

            while (rs.next()) out.add(map(rs));
        }
        return out;
    }

    /* =========================
       VOID
       ========================= */

    public void voidTransaction(long txnId, String reason) throws SQLException {
        String sql = """
            UPDATE transactions
            SET status = 'VOID', void_reason = ?, voided_at = datetime('now')
            WHERE txn_id = ?;
        """;

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, emptyToNull(reason));
            ps.setLong(2, txnId);
            ps.executeUpdate();
        }
    }

    /* =========================
       SUMS (VOID excluded ✅)
       ========================= */

    public long sumByTypeBetween(long customerId, String type, String fromIso, String toIso) throws SQLException {
        String sql = """
            SELECT COALESCE(SUM(amount_paise),0) AS s
            FROM transactions
            WHERE customer_id = ?
              AND status <> 'VOID'
              AND txn_type = ?
              AND txn_date >= ?
              AND txn_date <= ?;
        """;

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setLong(1, customerId);
            ps.setString(2, type);
            ps.setString(3, fromIso);
            ps.setString(4, toIso);

            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getLong("s") : 0;
            }
        }
    }

    public long sumAllByTypeBetween(String type, String fromIso, String toIso) throws SQLException {
        String sql = """
            SELECT COALESCE(SUM(amount_paise),0) AS s
            FROM transactions
            WHERE status <> 'VOID'
              AND txn_type = ?
              AND txn_date >= ?
              AND txn_date <= ?;
        """;

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, type);
            ps.setString(2, fromIso);
            ps.setString(3, toIso);

            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getLong("s") : 0;
            }
        }
    }

    /* =========================
       MAPPER + HELPERS
       ========================= */

    private Transaction map(ResultSet rs) throws SQLException {
        Transaction t = new Transaction();
        t.setTxnId(rs.getLong("txn_id"));
        t.setCustomerId(rs.getLong("customer_id"));
        t.setTxnDate(rs.getString("txn_date"));
        t.setTxnType(rs.getString("txn_type"));
        t.setAmountPaise(rs.getLong("amount_paise"));
        t.setReference(rs.getString("reference"));
        t.setNotes(rs.getString("notes"));
        t.setStatus(rs.getString("status"));
        t.setVoidReason(rs.getString("void_reason"));
        t.setVoidedAt(rs.getString("voided_at"));
        return t;
    }

    private String emptyToNull(String s) {
        if (s == null) return null;
        String t = s.trim();
        return t.isEmpty() ? null : t;
    }
}
