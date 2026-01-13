package com.gasstation.app.service;

import com.gasstation.app.dao.SettingsDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.CustomerKpi;
import com.gasstation.app.util.MoneyUtil;

import java.sql.SQLException;
import java.time.LocalDate;

/**
 * Central place for reminder/alert message generation.
 *
 * Supports:
 *  - Auto template selection by days overdue
 *  - Multi-language message templates (EN / TE)
 *  - Simple placeholders
 */
public class ReminderTemplateService {

    public static final String KEY_AUTO_GENTLE_MAX_DAYS = "reminder_auto_gentle_max_days";
    public static final String KEY_AUTO_OVERDUE_MAX_DAYS = "reminder_auto_overdue_max_days";
    public static final String KEY_FOLLOWUP_DAYS = "reminder_followup_days";
    public static final String KEY_DEFAULT_LANGUAGE = "reminder_default_language";

    public static final String KEY_BUSINESS_NAME = "business_name";
    public static final String KEY_BUSINESS_CONTACT = "business_contact";

    public static final String KEY_TPL_GENTLE_EN = "reminder_tpl_gentle_en";
    public static final String KEY_TPL_OVERDUE_EN = "reminder_tpl_overdue_en";
    public static final String KEY_TPL_FINAL_EN = "reminder_tpl_final_en";

    public static final String KEY_TPL_GENTLE_TE = "reminder_tpl_gentle_te";
    public static final String KEY_TPL_OVERDUE_TE = "reminder_tpl_overdue_te";
    public static final String KEY_TPL_FINAL_TE = "reminder_tpl_final_te";

    public enum Lang { EN, TE }
    public enum TemplateKey { AUTO, GENTLE, OVERDUE, FINAL }

    private final SettingsDao settingsDao = new SettingsDao();

    public int getFollowupDaysOrDefault(int fallback) {
        try {
            return settingsDao.getInt(KEY_FOLLOWUP_DAYS, fallback);
        } catch (SQLException e) {
            return fallback;
        }
    }

    public Lang getDefaultLang() {
        try {
            String v = settingsDao.get(KEY_DEFAULT_LANGUAGE, "EN");
            return parseLang(v);
        } catch (SQLException e) {
            return Lang.EN;
        }
    }

    public TemplateKey autoPick(int daysOverdue) {
        try {
            int gentleMax = settingsDao.getInt(KEY_AUTO_GENTLE_MAX_DAYS, 7);
            int overdueMax = settingsDao.getInt(KEY_AUTO_OVERDUE_MAX_DAYS, 30);
            if (daysOverdue <= Math.max(0, gentleMax)) return TemplateKey.GENTLE;
            if (daysOverdue <= Math.max(0, overdueMax)) return TemplateKey.OVERDUE;
            return TemplateKey.FINAL;
        } catch (SQLException e) {
            // Safe defaults
            if (daysOverdue <= 7) return TemplateKey.GENTLE;
            if (daysOverdue <= 30) return TemplateKey.OVERDUE;
            return TemplateKey.FINAL;
        }
    }

    public String render(TemplateKey templateKey, Lang lang, CustomerKpi kpi) {
        if (kpi == null || kpi.getCustomer() == null) return "";
        if (templateKey == null) templateKey = TemplateKey.AUTO;
        if (lang == null) lang = Lang.EN;

        Customer c = kpi.getCustomer();
        int days = Math.max(0, kpi.getMaxDaysOverdue());
        long overdue = Math.max(0, kpi.getOverdueAmountPaise());
        long total = Math.max(0, kpi.getTotalDuePaise());
        LocalDate today = LocalDate.now();
        LocalDate dueDate = today.minusDays(days);

        TemplateKey resolved = templateKey == TemplateKey.AUTO ? autoPick(days) : templateKey;

        String tpl = loadTemplate(resolved, lang);
        String businessName = load(KEY_BUSINESS_NAME, "");
        String businessContact = load(KEY_BUSINESS_CONTACT, "");

        // Small formatting helpers
        String businessLine = "";
        if (!businessName.isBlank() && !businessContact.isBlank()) {
            businessLine = businessName + " (" + businessContact + ")";
        } else if (!businessName.isBlank()) {
            businessLine = businessName;
        } else if (!businessContact.isBlank()) {
            businessLine = businessContact;
        }

        return tpl
                .replace("{NAME}", safe(c.getName()))
                .replace("{AMOUNT}", MoneyUtil.formatMoney(overdue))
                .replace("{TOTAL}", MoneyUtil.formatMoney(total))
                .replace("{DAYS}", Integer.toString(days))
                .replace("{DUE_DATE}", dueDate.toString())
                .replace("{TODAY}", today.toString())
                .replace("{BUSINESS_NAME}", businessLine)
                .replace("{BUSINESS_CONTACT}", safe(businessContact));
    }

    public Lang parseLang(String v) {
        if (v == null) return Lang.EN;
        String t = v.trim().toUpperCase();
        if (t.startsWith("TE")) return Lang.TE;
        return Lang.EN;
    }

    private String loadTemplate(TemplateKey key, Lang lang) {
        // Fallback templates are intentionally simple.
        String k;
        String fallback;

        if (lang == Lang.TE) {
            if (key == TemplateKey.GENTLE) {
                k = KEY_TPL_GENTLE_TE;
                fallback = "హాయ్ {NAME} గారు, మీ బాకీ మొత్తం {AMOUNT}. వీలైనప్పుడు చెల్లించండి. ధన్యవాదాలు. {BUSINESS_NAME}";
            } else if (key == TemplateKey.FINAL) {
                k = KEY_TPL_FINAL_TE;
                fallback = "హాయ్ {NAME} గారు, ఇది చివరి గుర్తు చేసేది: మీ బాకీ {AMOUNT} ({DAYS} రోజులు). దయచేసి ఈ రోజు తీర్చండి. {BUSINESS_NAME}";
            } else {
                k = KEY_TPL_OVERDUE_TE;
                fallback = "హాయ్ {NAME} గారు, మీ చెల్లింపు {DAYS} రోజు(లు) ఆలస్యం అయింది. బాకీ: {AMOUNT}. దయచేసి ఈ రోజు చెల్లించండి. {BUSINESS_NAME}";
            }
        } else {
            if (key == TemplateKey.GENTLE) {
                k = KEY_TPL_GENTLE_EN;
                fallback = "Hi {NAME}, just a friendly reminder: your pending amount is {AMOUNT}. Please pay when possible. Thanks. {BUSINESS_NAME}";
            } else if (key == TemplateKey.FINAL) {
                k = KEY_TPL_FINAL_EN;
                fallback = "Hi {NAME}, FINAL reminder: your overdue balance is {AMOUNT} ({DAYS} days). Please clear it today. {BUSINESS_NAME}";
            } else {
                k = KEY_TPL_OVERDUE_EN;
                fallback = "Hi {NAME}, your payment is overdue by {DAYS} day(s). Pending: {AMOUNT}. Please pay today. Thanks. {BUSINESS_NAME}";
            }
        }

        return load(k, fallback);
    }

    private String load(String key, String fallback) {
        try {
            return settingsDao.get(key, fallback);
        } catch (SQLException e) {
            return fallback;
        }
    }

    private String safe(String s) {
        return s == null ? "" : s;
    }
}
