package com.gasstation.app.model;

import java.time.LocalDate;

/**
 * Computed per-customer metrics for the business dashboard.
 * This is NOT stored in DB; we calculate it from transactions + settings.
 */
public class CustomerKpi {
    private Customer customer;

    private long principalBalancePaise;
    private long interestAccruedPaise;
    private long totalDuePaise;

    private long overdueAmountPaise;
    private int maxDaysOverdue;

    private LocalDate lastPaymentDate;
    private int paymentsLast30Days;

    private int riskScore;
    private String riskTag; // GREEN / YELLOW / RED

    public Customer getCustomer() { return customer; }
    public void setCustomer(Customer customer) { this.customer = customer; }

    public long getPrincipalBalancePaise() { return principalBalancePaise; }
    public void setPrincipalBalancePaise(long principalBalancePaise) { this.principalBalancePaise = principalBalancePaise; }

    public long getInterestAccruedPaise() { return interestAccruedPaise; }
    public void setInterestAccruedPaise(long interestAccruedPaise) { this.interestAccruedPaise = interestAccruedPaise; }

    public long getTotalDuePaise() { return totalDuePaise; }
    public void setTotalDuePaise(long totalDuePaise) { this.totalDuePaise = totalDuePaise; }

    public long getOverdueAmountPaise() { return overdueAmountPaise; }
    public void setOverdueAmountPaise(long overdueAmountPaise) { this.overdueAmountPaise = overdueAmountPaise; }

    public int getMaxDaysOverdue() { return maxDaysOverdue; }
    public void setMaxDaysOverdue(int maxDaysOverdue) { this.maxDaysOverdue = maxDaysOverdue; }

    public LocalDate getLastPaymentDate() { return lastPaymentDate; }
    public void setLastPaymentDate(LocalDate lastPaymentDate) { this.lastPaymentDate = lastPaymentDate; }

    public int getPaymentsLast30Days() { return paymentsLast30Days; }
    public void setPaymentsLast30Days(int paymentsLast30Days) { this.paymentsLast30Days = paymentsLast30Days; }

    public int getRiskScore() { return riskScore; }
    public void setRiskScore(int riskScore) { this.riskScore = riskScore; }

    public String getRiskTag() { return riskTag; }
    public void setRiskTag(String riskTag) { this.riskTag = riskTag; }
}
