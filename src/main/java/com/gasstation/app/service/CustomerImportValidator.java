package com.gasstation.app.service;

import com.gasstation.app.util.MoneyUtil;

import java.util.Set;

/**
 * Non-UI validation helpers for customer imports.
 *
 * These rules mirror CustomerImportScreen while keeping import validation
 * testable without launching JavaFX.
 */
public final class CustomerImportValidator {
    private CustomerImportValidator() {}

    public static CustomerImportRow validate(
            String name,
            String phone,
            String active,
            String creditLimit,
            String creditLimitPaise,
            String dueDays,
            String graceDays,
            Set<String> existingPhones
    ) {
        String normalizedName = safe(name).trim();
        String normalizedPhone = normalizePhone(phone);

        if (normalizedName.isEmpty() || normalizedPhone.isEmpty()) {
            return CustomerImportRow.invalid("Missing required fields (Name/Phone)");
        }

        if (existingPhones != null && existingPhones.contains(normalizedPhone)) {
            return CustomerImportRow.invalid("Duplicate phone: " + normalizedPhone);
        }

        long parsedCreditLimitPaise = parseCreditLimitPaise(creditLimit, creditLimitPaise);
        if (parsedCreditLimitPaise < 0) parsedCreditLimitPaise = 0;

        return CustomerImportRow.valid(
                normalizedName,
                normalizedPhone,
                parseActive(active),
                parsedCreditLimitPaise,
                parseIntOrDefault(dueDays, 30),
                Math.max(0, parseIntOrDefault(graceDays, 0))
        );
    }

    public static String normalizePhone(String s) {
        if (s == null) return "";
        String digits = s.replaceAll("\\D", "");
        if (digits.length() >= 10) return digits.substring(digits.length() - 10);
        return "";
    }

    public static int parseActive(String s) {
        if (s == null) return 1;
        String t = s.trim().toLowerCase();
        if (t.isEmpty()) return 1;
        if (t.equals("0") || t.equals("false") || t.equals("no") || t.equals("inactive")) return 0;
        return 1;
    }

    public static int parseIntOrDefault(String s, int fallback) {
        if (s == null || s.trim().isEmpty()) return fallback;
        try { return Integer.parseInt(s.trim()); }
        catch (Exception e) { return fallback; }
    }

    public static long parseLongOrZero(String s) {
        if (s == null || s.trim().isEmpty()) return 0;
        try { return Long.parseLong(s.trim()); }
        catch (Exception e) { return 0; }
    }

    public static long parseCreditLimitPaise(String creditLimit, String creditLimitPaise) {
        String clPaise = safe(creditLimitPaise);
        String cl = safe(creditLimit);
        if (!clPaise.isEmpty()) return parseLongOrZero(clPaise);
        if (cl.isEmpty()) return 0;

        try {
            return MoneyUtil.parseMoneyToPaise(cl);
        } catch (IllegalArgumentException | ArithmeticException e) {
            return 0;
        }
    }

    private static String safe(String s) {
        return s == null ? "" : s;
    }

    public record CustomerImportRow(
            boolean valid,
            String failureReason,
            String name,
            String phone,
            int isActive,
            long creditLimitPaise,
            int dueDays,
            int graceDays
    ) {
        static CustomerImportRow valid(String name, String phone, int isActive, long creditLimitPaise, int dueDays, int graceDays) {
            return new CustomerImportRow(true, "", name, phone, isActive, creditLimitPaise, dueDays, graceDays);
        }

        static CustomerImportRow invalid(String failureReason) {
            return new CustomerImportRow(false, failureReason, "", "", 1, 0, 30, 0);
        }
    }
}
