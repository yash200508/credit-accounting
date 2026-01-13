@echo off
setlocal

set "APP_NAME=Gas Station Credit Accounting"
set "VERSION=0.0.1"
set "JAR=credit-accounting-0.0.1-SNAPSHOT.jar"
set "MAIN_CLASS=com.gasstation.app.App"

echo Building app-image (JavaFX + deps)...

REM 1) Build main jar
call mvn -q clean package
if errorlevel 1 (
  echo Maven build failed.
  pause
  exit /b 1
)

REM 2) Copy dependencies into target\lib (clean deletes it!)
call mvn -q -DskipTests dependency:copy-dependencies -DoutputDirectory=target\lib
if errorlevel 1 (
  echo Dependency copy failed.
  pause
  exit /b 1
)

REM 3) Clean output folder
if exist "dist\%APP_NAME%" rmdir /s /q "dist\%APP_NAME%"
if not exist dist mkdir dist

REM 4) Build app-image
jpackage --type app-image ^
  --name "%APP_NAME%" ^
  --app-version "%VERSION%" ^
  --input target ^
  --main-jar "%JAR%" ^
  --main-class "%MAIN_CLASS%" ^
  --vendor "GasStation Software" ^
  --module-path "fx" ^
  --add-modules "javafx.controls,javafx.fxml,java.sql,java.desktop,java.naming" ^
  --java-options "-cp app\%JAR%;app\lib\*" ^
  --win-console ^
  --dest dist

echo.
echo Output:
echo dist\%APP_NAME%\%APP_NAME%.exe
echo.
pause
