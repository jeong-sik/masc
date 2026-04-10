"""Entry point: python -m src.bot"""
from .bot import main

if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
