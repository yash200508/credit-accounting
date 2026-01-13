package com.gasstation.app.dao;

import com.gasstation.app.db.Db;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;

public class AuditDao {

    public void log(String action, String entity, Long entityId, String details) {
        String sql = """
            INSERT INTO audit_log(action, entity, entity_id, details)
            VALUES(?,?,?,?);
        """;
        try (Connection conn = Db.getConnection(); PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setString(1, action == null ? "" : action);
            ps.setString(2, entity == null ? "" : entity);
            if (entityId == null) ps.setNull(3, java.sql.Types.INTEGER); else ps.setLong(3, entityId);
            ps.setString(4, details);
            ps.executeUpdate();
        } catch (SQLException ignored) {
            // Audit should never break core flows.
        }
    }
}
