#!/usr/bin/python3
"""Answer screenshot fixture requests without calling Audible or reading an auth file."""

import json
from pathlib import Path
import sys


def demo_book(number):
    return {
        "asin": f"DEMOBOOK{number:02}",
        "title": f"Demo Book {number}",
        "authors": [f"Demo Author {number}"],
        "narrators": [f"Demo Narrator {number}"],
        "series": "Demo Series",
        "seriesSequence": str(number),
        "durationSeconds": 18000 + number * 800,
        "hasPDF": False,
        "isDownloadable": True,
    }


request = json.loads(sys.stdin.readline())
command = request["command"]
if command == "cliProfiles":
    result = [{
        "name": "Demo Account",
        "authFile": Path(request["file"]).with_name("demo-account.json").as_uri(),
        "marketplace": "uk",
        "isDefault": True,
        "requiresPassword": True,
    }]
elif command == "wishlist":
    result = [demo_book(number) for number in range(7, 10)]
elif command == "catalog":
    result = [demo_book(number) for number in range(10, 14)]
elif command == "inspectAuthFile":
    result = True
elif command == "inspectOpenAudible":
    result = [
        {"name": "Demo Account", "marketplace": "uk", "isDefault": True, "checkpoint": "1" * 64},
        {"name": "Demo Account 2", "marketplace": "us", "isDefault": False, "checkpoint": "2" * 64},
    ]
else:
    sys.exit(1)
print(json.dumps({"result": result}), flush=True)
