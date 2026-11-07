@echo off
rem Windows shim: forward rclone arguments to the hermetic Python stub.
rem (PowerShell invokes this because Get-RcloneBin returns it; the stub is
rem the same tests/fake_rclone the Linux suite uses.)
python "%~dp0fake_rclone" %*
