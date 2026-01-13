package com.gasstation.app.dao;

import com.gasstation.app.db.Db;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

public class ReminderDao {

    public static class ReminderRow {
        public long reminderId;
        public long customerId;
        public String createdAt;
        public String dueDate;
        public int daysPastDue;
        public long amountPaise;
        public String templateKey;
        public String messageText;
        public String channel;
        public String sentStatus;
        public String sentBy;
    }

    public long insert(long customerId,
                       String dueDate,
                       int daysPastDue,
                       long amountPaise,
                       String templateKey,
                       String messageText,
                       String channel,
                       String sentBy) throws SQLException {
        String sql = """
            INSERT INTO reminders(customer_id, due_date, days_past_due, amount_paise,
                                 template_key, message_text, channel, sent_by)
            VALUES(?,?,?,?,?,?,?,?);
        """;

        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql, PreparedStatement.RETURN_GENERATED_KEYS)) {

            ps.setLong(1, customerId);
            ps.setString(2, dueDate);
            ps.setInt(3, Math.max(0, daysPastDue));
            ps.setLong(4, Math.max(0, amountPaise));
            ps.setString(5, templateKey == null ? "OVERDUE" : templateKey);
            ps.setString(6, messageText == null ? "" : messageText);
            ps.setString(7, channel == null ? "WHATSAPP" : channel);
            ps.setString(8, sentBy);
            ps.executeUpdate();

            try (ResultSet rs = ps.getGeneratedKeys()) {
                if (rs.next()) return rs.getLong(1);
            }
            return -1;
        }
    }

    public List<ReminderRow> listByCustomer(long customerId, int limit) throws SQLException {
        String sql = """
            SELECT reminder_id, customer_id, created_at, due_date, days_past_due, amount_paise,
                   template_key, message_text, channel, sent_status, sent_by
            FROM reminders
            WHERE customer_id = ?
            ORDER BY created_at DESC
            LIMIT ?;
        """;
        List<ReminderRow> out = new ArrayList<>();
        try (Connection conn = Db.getConnection(); PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setLong(1, customerId);
            ps.setInt(2, Math.max(1, limit));
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    ReminderRow r = new ReminderRow();
                    r.reminderId = rs.getLong("reminder_id");
                    r.customerId = rs.getLong("customer_id");
                    r.createdAt = rs.getString("created_at");
                    r.dueDate = rs.getString("due_date");
                    r.daysPastDue = rs.getInt("days_past_due");
                    r.amountPaise = rs.getLong("amount_paise");
                    r.templateKey = rs.getString("template_key");
                    r.messageText = rs.getString("message_text");
                    r.channel = rs.getString("channel");
                    r.sentStatus = rs.getString("sent_status");
                    r.sentBy = rs.getString("sent_by");
                    out.add(r);
                }
            }
        }
        return out;
    }
}
