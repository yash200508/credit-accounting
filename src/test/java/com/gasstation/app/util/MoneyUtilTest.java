package com.gasstation.app.util;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class MoneyUtilTest {

    @Test
    void parsesWholeRupeeValuesToIntegerPaise() {
        assertEquals(0L, MoneyUtil.parseMoneyToPaise("0"));
        assertEquals(100L, MoneyUtil.parseMoneyToPaise("1"));
        assertEquals(9_900L, MoneyUtil.parseMoneyToPaise("99"));
    }

    @Test
    void parsesTwoDecimalCurrencyAndCommaValues() {
        assertEquals(12_345L, MoneyUtil.parseMoneyToPaise("123.45"));
        assertEquals(123_450L, MoneyUtil.parseMoneyToPaise("₹1,234.50"));
        assertEquals(1_234L, MoneyUtil.parseMoneyToPaise("+12.34"));
        assertEquals(-1_234L, MoneyUtil.parseMoneyToPaise("-12.34"));
    }

    @Test
    void rejectsInvalidBlankNullAndOverPreciseValues() {
        assertThrows(IllegalArgumentException.class, () -> MoneyUtil.parseMoneyToPaise(null));
        assertThrows(IllegalArgumentException.class, () -> MoneyUtil.parseMoneyToPaise("   "));
        assertThrows(IllegalArgumentException.class, () -> MoneyUtil.parseMoneyToPaise("abc"));
        assertThrows(IllegalArgumentException.class, () -> MoneyUtil.parseMoneyToPaise("12.345"));
        assertThrows(IllegalArgumentException.class, () -> MoneyUtil.parseMoneyToPaise("1.2.3"));
    }

    @Test
    void formatsZeroPositiveAndNegativePaise() {
        assertEquals("₹0.00", MoneyUtil.formatMoney(0));
        assertEquals("₹123.45", MoneyUtil.formatMoney(12_345));
        assertEquals("₹-0.50", MoneyUtil.formatMoney(-50));
        assertEquals("₹-123.45", MoneyUtil.formatMoney(-12_345));
    }

    @Test
    void preservesIntegerPaiseWithoutFloatingPointRounding() {
        assertEquals(10L, MoneyUtil.parseMoneyToPaise("0.10"));
        assertEquals(20L, MoneyUtil.parseMoneyToPaise("0.20"));
        assertEquals(30L, MoneyUtil.parseMoneyToPaise("0.30"));
    }
}
