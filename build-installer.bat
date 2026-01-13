@echo off
setlocal

REM No spaces here to avoid WiX/jpackage quoting bugs
set "APP_NAME=GasStationCreditAccounting"
set "DISPLAY_NAME=Gas Station Credit Accounting"
set "VERSION=0.0.1"
set "JAR=credit-accounting-0.0.1-SNAPSHOT.jar"
set "MAIN_CLASS=com.gasstation.app.App"

echo Building Windows Installer (MSI)...

call mvn -q clean package || goto :err
call mvn -q -DskipTests dependency:copy-dependencies -DoutputDirectory=target\lib || goto :err

if exist dist rmdir /s /q dist
mkdir dist

jpackage --type msi ^
--name "%APP_NAME%" ^
--app-version "%VERSION%" ^
--input target ^
--main-jar "%JAR%" ^
--main-class "%MAIN_CLASS%" ^
--vendor "GasStation Software" ^
--description "%DISPLAY_NAME%" ^
--win-menu ^
--win-shortcut ^
--icon "installer-resources\icon.ico" ^
--resource-dir "installer-resources" ^
--module-path "fx" ^
--add-modules "javafx.controls,javafx.fxml,java.sql,java.desktop,java.naming" ^
--java-options "-cp app\%JAR%;app\lib\*" ^
--dest dist

echo.
echo MSI created in dist\
echo.
pause
exit /b 0

:err
echo.
echo Build failed.
pause
exit /b 1
