package com.gasstation.app.model;

public class Customer {
    private long customerId;
    private String name;
    private String phone;
    private String address;
    private String notes;

    // NEW: active/inactive flag (1 = active, 0 = inactive)
    private int isActive = 1;

    // Business controls
    private long creditLimitPaise = 0;
    private int dueDays = 30;
    private int graceDays = 0;

    // Collections / risk
    private int riskScore = 0;
    private String riskLevel = "LOW"; // LOW / MEDIUM / HIGH
    private String nextFollowupDate;   // ISO yyyy-MM-dd
    private String followupNotes;

    public Customer() {}

    public Customer(String name, String phone, String address, String notes) {
        this.name = name;
        this.phone = phone;
        this.address = address;
        this.notes = notes;
        this.isActive = 1;
    }

    // Optional convenience constructor if you ever want to set active explicitly
    public Customer(String name, String phone, String address, String notes, int isActive) {
        this.name = name;
        this.phone = phone;
        this.address = address;
        this.notes = notes;
        this.isActive = isActive;
    }

    public long getCustomerId() { return customerId; }
    public void setCustomerId(long customerId) { this.customerId = customerId; }

    public String getName() { return name; }
    public void setName(String name) { this.name = name; }

    public String getPhone() { return phone; }
    public void setPhone(String phone) { this.phone = phone; }

    public String getAddress() { return address; }
    public void setAddress(String address) { this.address = address; }

    public String getNotes() { return notes; }
    public void setNotes(String notes) { this.notes = notes; }

    // NEW getters/setters
    public int getIsActive() { return isActive; }
    public void setIsActive(int isActive) { this.isActive = isActive; }

    public long getCreditLimitPaise() { return creditLimitPaise; }
    public void setCreditLimitPaise(long creditLimitPaise) { this.creditLimitPaise = creditLimitPaise; }

    public int getDueDays() { return dueDays; }
    public void setDueDays(int dueDays) { this.dueDays = dueDays; }

    public int getGraceDays() { return graceDays; }
    public void setGraceDays(int graceDays) { this.graceDays = graceDays; }

    public int getRiskScore() { return riskScore; }
    public void setRiskScore(int riskScore) { this.riskScore = riskScore; }

    public String getRiskLevel() { return riskLevel; }
    public void setRiskLevel(String riskLevel) { this.riskLevel = riskLevel; }

    public String getNextFollowupDate() { return nextFollowupDate; }
    public void setNextFollowupDate(String nextFollowupDate) { this.nextFollowupDate = nextFollowupDate; }

    public String getFollowupNotes() { return followupNotes; }
    public void setFollowupNotes(String followupNotes) { this.followupNotes = followupNotes; }
}
