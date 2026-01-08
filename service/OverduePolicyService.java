package com.gasstation.app.service;

import com.gasstation.app.dao.SettingsDao;

import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

public class OverduePolicyService {

    public static final String KEY_BUCKET1_MAX = "overdue_bucket1_max"; // default 7
    public static final String KEY_BUCKET2_MAX = "overdue_bucket2_max"; // default 15
    public static final String KEY_BUCKET3_MAX = "overdue_bucket3_max"; // default 30
    public static final String KEY_BUCKET4_MAX = "overdue_bucket4_max"; // default 60

    private final SettingsDao settingsDao = new SettingsDao();

    public int getBucket1Max() { return getInt(KEY_BUCKET1_MAX, 7); }
    public int getBucket2Max() { return getInt(KEY_BUCKET2_MAX, 15); }
    public int getBucket3Max() { return getInt(KEY_BUCKET3_MAX, 30); }
    public int getBucket4Max() { return getInt(KEY_BUCKET4_MAX, 60); }

    public List<String> bucketLabels() {
        int b1 = sanitize(getBucket1Max());
        int b2 = sanitize(getBucket2Max());
        int b3 = sanitize(getBucket3Max());
        int b4 = sanitize(getBucket4Max());

        if (b2 < b1) b2 = b1;
        if (b3 < b2) b3 = b2;
        if (b4 < b3) b4 = b3;

        List<String> out = new ArrayList<>();
        out.add("All");
        out.add("0-" + b1);
        out.add((b1 + 1) + "-" + b2);
        out.add((b2 + 1) + "-" + b3);
        out.add((b3 + 1) + "-" + b4);
        out.add((b4 + 1) + "+");
        return out;
    }

    public String bucketOf(int days) {
        int d = Math.max(0, days);
        int b1 = sanitize(getBucket1Max());
        int b2 = Math.max(b1, sanitize(getBucket2Max()));
        int b3 = Math.max(b2, sanitize(getBucket3Max()));
        int b4 = Math.max(b3, sanitize(getBucket4Max()));

        if (d <= b1) return "0-" + b1;
        if (d <= b2) return (b1 + 1) + "-" + b2;
        if (d <= b3) return (b2 + 1) + "-" + b3;
        if (d <= b4) return (b3 + 1) + "-" + b4;
        return (b4 + 1) + "+";
    }

    private int getInt(String key, int fallback) {
        try {
            return settingsDao.getInt(key, fallback);
        } catch (SQLException e) {
            return fallback;
        }
    }

    private int sanitize(int v) {
        if (v < 0) return 0;
        if (v > 3650) return 3650;
        return v;
    }
}
