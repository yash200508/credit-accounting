package com.gasstation.app.util;

public final class MoneyUtil {
    private MoneyUtil() {}

    public static String formatMoney(long paise) {
        long rupees = paise / 100;
        long p = Math.abs(paise % 100);
        return "₹" + rupees + "." + (p < 10 ? "0" + p : p);
    }
}
