package com.gasstation.app.service;

import com.gasstation.app.util.MoneyUtil;

/**
 * Non-UI validation helpers for transaction imports.
 *
 * Keeping these rules outside the JavaFX screen makes amount/type behavior
 * testable without launching the desktop UI.
 */
public final class TransactionImportValidator {
    private TransactionImportValidator() {}

    public static String normalizeType(String type) {
        String t = safe(type).toUpperCase();

        if (t.equals("DEBIT") || t.equals("CREDIT")) return t;

        if (t.contains("CREDIT TAKEN") || t.contains("TAKEN") || t.contains("FUEL")) return "DEBIT";
        if (t.contains("PAYMENT") || t.contains("PAID") || t.contains("RECEIVED")) return "CREDIT";

        return null;
    }

    public static long parseRupeesToPaise(String text) {
        String t = safe(text);
        if (t.isEmpty()) return 0;

        t = t.replace("Rs.", "")
                .replace("rs.", "")
                .replace("Rs", "")
                .replace("rs", "")
                .trim();

        try {
            return MoneyUtil.parseMoneyToPaise(t);
        } catch (IllegalArgumentException | ArithmeticException e) {
            return 0;
        }
    }

    public static boolean hasRequiredFields(String phone, String date, String type, String amount, String amountPaise) {
        return !safe(phone).isEmpty()
                && !safe(date).isEmpty()
                && !safe(type).isEmpty()
                && (!safe(amount).isEmpty() || !safe(amountPaise).isEmpty());
    }

    private static String safe(String s) {
        return s == null ? "" : s.trim();
    }
}
