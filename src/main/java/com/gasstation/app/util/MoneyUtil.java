package com.gasstation.app.util;

import java.math.BigDecimal;
import java.math.RoundingMode;

public final class MoneyUtil {
    private MoneyUtil() {}

    public static String formatMoney(long paise) {
        boolean negative = paise < 0;
        long absolutePaise = Math.abs(paise);
        long rupees = absolutePaise / 100;
        long p = absolutePaise % 100;
        return "₹" + (negative ? "-" : "") + rupees + "." + (p < 10 ? "0" + p : p);
    }

    /**
     * Parses a rupee amount into integer paise without using floating-point arithmetic.
     *
     * Accepted examples: "123", "123.45", "₹123.45", "1,234.50".
     * The amount must contain no more than two decimal places.
     */
    public static long parseMoneyToPaise(String value) {
        if (value == null) throw new IllegalArgumentException("Amount is required");

        String normalized = value.trim()
                .replace("₹", "")
                .replace(",", "")
                .trim();

        if (normalized.isEmpty()) throw new IllegalArgumentException("Amount is required");
        if (!normalized.matches("[-+]?\\d+(\\.\\d{1,2})?")) {
            throw new IllegalArgumentException("Amount must be a number with at most 2 decimal places");
        }

        return new BigDecimal(normalized)
                .movePointRight(2)
                .setScale(0, RoundingMode.UNNECESSARY)
                .longValueExact();
    }
}
