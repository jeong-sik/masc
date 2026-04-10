"""Entry point: python -m src [keeper_name]."""

import asyncio
import sys

from .bot import main

keeper = sys.argv[1] if len(sys.argv) > 1 else None
asyncio.run(main(keeper_override=keeper))
