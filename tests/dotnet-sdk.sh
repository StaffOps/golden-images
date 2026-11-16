# shellcheck shell=bash
check "dotnet --version"        --entrypoint dotnet "$IMG" --version
check "new console + run"       --entrypoint bash "$IMG" -c 'set -e; cd /tmp && dotnet new console -o app >/dev/null && cd app && dotnet run'
check "ICU globalization"       --entrypoint bash "$IMG" -c 'set -e; cd /tmp && dotnet new console -o c >/dev/null && cd c && echo "System.Console.WriteLine(System.Globalization.CultureInfo.CurrentCulture.Name + \" \" + (1234.5m).ToString(\"N\"));" > Program.cs && dotnet run'
