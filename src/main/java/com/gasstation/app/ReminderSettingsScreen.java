package com.gasstation.app;

import com.gasstation.app.dao.SettingsDao;
import com.gasstation.app.service.ReminderTemplateService;
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.layout.*;

import java.sql.SQLException;

/**
 * Business-facing reminder/alert configuration.
 *
 * Lets owner customize:
 *  - Auto-template thresholds (by days overdue)
 *  - Default language (EN / TE)
 *  - Follow-up interval
 *  - Message templates (English + Telugu)
 */
public class ReminderSettingsScreen extends BorderPane {

    private final AppNavigator nav;
    private final SettingsDao settingsDao = new SettingsDao();

    private final ComboBox<String> defaultLangBox = new ComboBox<>();
    private final TextField gentleMaxDaysField = new TextField();
    private final TextField overdueMaxDaysField = new TextField();
    private final TextField followupDaysField = new TextField();
    private final TextField businessNameField = new TextField();
    private final TextField businessContactField = new TextField();

    private final TextArea gentleEn = new TextArea();
    private final TextArea overdueEn = new TextArea();
    private final TextArea finalEn = new TextArea();

    private final TextArea gentleTe = new TextArea();
    private final TextArea overdueTe = new TextArea();
    private final TextArea finalTe = new TextArea();

    private final Label statusLbl = new Label(" ");

    public ReminderSettingsScreen(AppNavigator nav) {
        this.nav = nav;
        setPadding(new Insets(12));

        // ✅ Top bar (Back button)
        Button backBtn = new Button("← Back to Settings");
        backBtn.setOnAction(e -> nav.showSettings());

        Label title = new Label("Reminder Settings");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        HBox top = new HBox(10, backBtn, title);
        top.setPadding(new Insets(0, 0, 10, 0));
        setTop(new VBox(top, new Separator()));

        // --- policy form ---
        GridPane form = new GridPane();
        form.setHgap(10);
        form.setVgap(10);
        form.setPadding(new Insets(10, 0, 0, 0));

        defaultLangBox.getItems().setAll("EN", "TE");

        form.add(new Label("Default reminder language"), 0, 0);
        form.add(defaultLangBox, 1, 0);

        form.add(new Label("Auto template: Gentle max days overdue"), 0, 1);
        form.add(gentleMaxDaysField, 1, 1);

        form.add(new Label("Auto template: Overdue max days overdue"), 0, 2);
        form.add(overdueMaxDaysField, 1, 2);

        form.add(new Label("Follow-up interval (days)"), 0, 3);
        form.add(followupDaysField, 1, 3);

        form.add(new Label("Business name (optional)"), 0, 4);
        form.add(businessNameField, 1, 4);

        form.add(new Label("Business contact (optional)"), 0, 5);
        form.add(businessContactField, 1, 5);

        // --- templates ---
        TabPane tabs = new TabPane();
        tabs.getTabs().add(buildTemplateTab("English", gentleEn, overdueEn, finalEn));
        tabs.getTabs().add(buildTemplateTab("Telugu", gentleTe, overdueTe, finalTe));
        tabs.setTabClosingPolicy(TabPane.TabClosingPolicy.UNAVAILABLE);

        Label help = new Label("Placeholders: {NAME} {AMOUNT} {DAYS} {TOTAL} {DUE_DATE} {TODAY} {BUSINESS_NAME}");
        help.setStyle("-fx-text-fill: #666;");

        Button saveBtn = new Button("Save");
        saveBtn.setOnAction(e -> save());

        Button resetBtn = new Button("Reset to Defaults");
        resetBtn.setOnAction(e -> resetToDefaults());

        HBox actions = new HBox(10, saveBtn, resetBtn);
        statusLbl.setStyle("-fx-text-fill: #666;");

        VBox center = new VBox(12,
                new Label("These settings control how the Reminders screen generates messages."),
                form,
                new Separator(),
                new Label("Message Templates"),
                help,
                tabs,
                actions,
                statusLbl
        );
        VBox.setVgrow(tabs, Priority.ALWAYS);
        setCenter(center);

        configureAreas();
        load();
    }

    private void configureAreas() {
        for (TextArea ta : new TextArea[]{gentleEn, overdueEn, finalEn, gentleTe, overdueTe, finalTe}) {
            ta.setWrapText(true);
            ta.setPrefRowCount(6);
        }
    }

    private Tab buildTemplateTab(String label, TextArea gentle, TextArea overdue, TextArea fin) {
        GridPane grid = new GridPane();
        grid.setHgap(10);
        grid.setVgap(10);
        grid.setPadding(new Insets(10));

        grid.add(new Label("GENTLE"), 0, 0);
        grid.add(gentle, 0, 1);

        grid.add(new Label("OVERDUE"), 0, 2);
        grid.add(overdue, 0, 3);

        grid.add(new Label("FINAL"), 0, 4);
        grid.add(fin, 0, 5);

        ColumnConstraints col = new ColumnConstraints();
        col.setHgrow(Priority.ALWAYS);
        grid.getColumnConstraints().add(col);

        Tab t = new Tab(label);
        t.setContent(grid);
        return t;
    }

    private void load() {
        try {
            defaultLangBox.setValue(settingsDao.get(ReminderTemplateService.KEY_DEFAULT_LANGUAGE, "EN"));
            gentleMaxDaysField.setText(settingsDao.get(ReminderTemplateService.KEY_AUTO_GENTLE_MAX_DAYS, "7"));
            overdueMaxDaysField.setText(settingsDao.get(ReminderTemplateService.KEY_AUTO_OVERDUE_MAX_DAYS, "30"));
            followupDaysField.setText(settingsDao.get(ReminderTemplateService.KEY_FOLLOWUP_DAYS, "7"));
            businessNameField.setText(settingsDao.get(ReminderTemplateService.KEY_BUSINESS_NAME, ""));
            businessContactField.setText(settingsDao.get(ReminderTemplateService.KEY_BUSINESS_CONTACT, ""));

            gentleEn.setText(settingsDao.get(ReminderTemplateService.KEY_TPL_GENTLE_EN, ""));
            overdueEn.setText(settingsDao.get(ReminderTemplateService.KEY_TPL_OVERDUE_EN, ""));
            finalEn.setText(settingsDao.get(ReminderTemplateService.KEY_TPL_FINAL_EN, ""));

            gentleTe.setText(settingsDao.get(ReminderTemplateService.KEY_TPL_GENTLE_TE, ""));
            overdueTe.setText(settingsDao.get(ReminderTemplateService.KEY_TPL_OVERDUE_TE, ""));
            finalTe.setText(settingsDao.get(ReminderTemplateService.KEY_TPL_FINAL_TE, ""));

            statusLbl.setText("Loaded");
        } catch (SQLException e) {
            statusLbl.setText("Error: " + e.getMessage());
            new Alert(Alert.AlertType.ERROR, "Failed to load reminder settings\n\n" + e.getMessage()).showAndWait();
        }
    }

    private void save() {
        try {
            String lang = (defaultLangBox.getValue() == null) ? "EN" : defaultLangBox.getValue().trim().toUpperCase();
            if (!lang.equals("EN") && !lang.equals("TE")) lang = "EN";

            int gentleMax = Integer.parseInt(gentleMaxDaysField.getText().trim());
            int overdueMax = Integer.parseInt(overdueMaxDaysField.getText().trim());
            int followup = Integer.parseInt(followupDaysField.getText().trim());

            if (gentleMax < 0 || gentleMax > 3650) throw new NumberFormatException("Gentle max days looks too large");
            if (overdueMax < 0 || overdueMax > 3650) throw new NumberFormatException("Overdue max days looks too large");
            if (overdueMax < gentleMax) throw new NumberFormatException("Overdue max days must be >= Gentle max days");
            if (followup < 0 || followup > 3650) throw new NumberFormatException("Follow-up days looks too large");

            settingsDao.set(ReminderTemplateService.KEY_DEFAULT_LANGUAGE, lang);
            settingsDao.set(ReminderTemplateService.KEY_AUTO_GENTLE_MAX_DAYS, Integer.toString(gentleMax));
            settingsDao.set(ReminderTemplateService.KEY_AUTO_OVERDUE_MAX_DAYS, Integer.toString(overdueMax));
            settingsDao.set(ReminderTemplateService.KEY_FOLLOWUP_DAYS, Integer.toString(followup));

            settingsDao.set(ReminderTemplateService.KEY_BUSINESS_NAME, businessNameField.getText() == null ? "" : businessNameField.getText().trim());
            settingsDao.set(ReminderTemplateService.KEY_BUSINESS_CONTACT, businessContactField.getText() == null ? "" : businessContactField.getText().trim());

            settingsDao.set(ReminderTemplateService.KEY_TPL_GENTLE_EN, textOrEmpty(gentleEn));
            settingsDao.set(ReminderTemplateService.KEY_TPL_OVERDUE_EN, textOrEmpty(overdueEn));
            settingsDao.set(ReminderTemplateService.KEY_TPL_FINAL_EN, textOrEmpty(finalEn));

            settingsDao.set(ReminderTemplateService.KEY_TPL_GENTLE_TE, textOrEmpty(gentleTe));
            settingsDao.set(ReminderTemplateService.KEY_TPL_OVERDUE_TE, textOrEmpty(overdueTe));
            settingsDao.set(ReminderTemplateService.KEY_TPL_FINAL_TE, textOrEmpty(finalTe));

            statusLbl.setText("Saved ✅");
        } catch (NumberFormatException nfe) {
            new Alert(Alert.AlertType.WARNING, "Please enter valid numbers.\n\n" + nfe.getMessage()).showAndWait();
        } catch (SQLException e) {
            statusLbl.setText("Error: " + e.getMessage());
            new Alert(Alert.AlertType.ERROR, "Failed to save reminder settings\n\n" + e.getMessage()).showAndWait();
        }
    }

    private void resetToDefaults() {
        defaultLangBox.setValue("EN");
        gentleMaxDaysField.setText("7");
        overdueMaxDaysField.setText("30");
        followupDaysField.setText("7");
        businessNameField.setText("");
        businessContactField.setText("");

        gentleEn.setText("Hi {NAME}, just a friendly reminder: your pending amount is {AMOUNT}. Please pay when possible. Thanks. {BUSINESS_NAME}");
        overdueEn.setText("Hi {NAME}, your payment is overdue by {DAYS} day(s). Pending: {AMOUNT}. Please pay today. Thanks. {BUSINESS_NAME}");
        finalEn.setText("Hi {NAME}, FINAL reminder: your overdue balance is {AMOUNT} ({DAYS} days). Please clear it today. {BUSINESS_NAME}");

        gentleTe.setText("హాయ్ {NAME} గారు, మీ బాకీ మొత్తం {AMOUNT}. వీలైనప్పుడు చెల్లించండి. ధన్యవాదాలు. {BUSINESS_NAME}");
        overdueTe.setText("హాయ్ {NAME} గారు, మీ చెల్లింపు {DAYS} రోజు(లు) ఆలస్యం అయింది. బాకీ: {AMOUNT}. దయచేసి ఈ రోజు చెల్లించండి. {BUSINESS_NAME}");
        finalTe.setText("హాయ్ {NAME} గారు, ఇది చివరి గుర్తు చేసేది: మీ బాకీ {AMOUNT} ({DAYS} రోజులు). దయచేసి ఈ రోజు తీర్చండి. {BUSINESS_NAME}");

        statusLbl.setText("Defaults loaded (click Save to apply)");
    }

    private String textOrEmpty(TextArea ta) {
        if (ta == null || ta.getText() == null) return "";
        return ta.getText().trim();
    }
}
