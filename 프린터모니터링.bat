@echo off
chcp 65001 >nul
title 프린터 모니터링 에이전트

REM ================================================
REM  프린터 모니터링 에이전트 v1.0
REM  Firebase 직접 전송 방식 (서버 불필요)
REM ================================================

REM ── 설정 (수정 필요한 부분) ──────────────────────
set FIREBASE_PROJECT=rental-management-8c377
set FIREBASE_API_KEY=AIzaSyAoEuQ_femEy46c07wIHXY3WykfXvqZRgk
set COMPANY_NAME=우리회사
REM ────────────────────────────────────────────────

echo.
echo  ========================================
echo   프린터 모니터링 에이전트 시작
echo   %date% %time%
echo  ========================================
echo.

REM PowerShell 스크립트 실행
powershell -ExecutionPolicy Bypass -File "%~dp0monitor.ps1"

echo.
echo  ✅ 수집 완료! Firebase에 저장되었습니다.
echo  ========================================
echo.
