@echo off
echo "Maven local repository will be set to %CD%\.cachepacotes\maven"
call mvn.cmd %* -Dmaven.repo.local="%CD%\.cachepacotes\maven"
