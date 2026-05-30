#!/usr/bin/env python3
"""兼容入口：新版部署逻辑已统一放在 wow.sh。"""
from __future__ import annotations
import os
import subprocess
from pathlib import Path

script = Path(__file__).with_name('wow.sh')
if not script.exists():
    raise SystemExit('未找到 wow.sh，请确认完整上传 GitHub 仓库。')
os.execvp('bash', ['bash', str(script)])
