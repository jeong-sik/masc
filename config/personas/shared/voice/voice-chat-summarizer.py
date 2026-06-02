#!/usr/bin/env python3
"""
Voice Chat Summarizer for Daily Retrospectives
Analyzes JSONL exchanges and creates session-style summaries
"""
import json
import sys
from pathlib import Path
from datetime import datetime
from collections import defaultdict

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')

def summarize_voice_chats(date_str: str):
    """
    Summarize voice chats for a given date (YYYY-MM-DD)
    Returns: dict with conversation_id -> summary
    """
    home = Path.home()
    jsonl_file = home / ".voicemode/logs/conversations" / f"exchanges_{date_str}.jsonl"
    
    if not jsonl_file.exists():
        return {}
    
    # Group by conversation_id
    conversations = defaultdict(list)
    
    with open(jsonl_file, 'r') as f:
        for line in f:
            try:
                entry = json.loads(line)
                conv_id = entry.get('conversation_id', 'unknown')
                conversations[conv_id].append(entry)
            except json.JSONDecodeError:
                continue
    
    summaries = {}
    
    for conv_id, entries in conversations.items():
        # Extract timestamps
        timestamps = [e.get('timestamp', '') for e in entries if e.get('timestamp')]
        if not timestamps:
            continue
            
        start_time = min(timestamps)
        end_time = max(timestamps)
        
        # Parse times
        try:
            start_dt = datetime.fromisoformat(start_time.replace('+09:00', ''))
            end_dt = datetime.fromisoformat(end_time.replace('+09:00', ''))
            duration_min = int((end_dt - start_dt).total_seconds() / 60)
            time_str = start_dt.strftime('%H:%M')
        except:
            time_str = "unknown"
            duration_min = 0
        
        # Count exchanges and extract user messages
        user_messages = []
        for e in entries:
            if e.get('type') in ['user_message', 'stt']:
                text = e.get('text', '').strip()
                if text and len(text) > 3:
                    user_messages.append(text)
        
        exchange_count = len(entries)
        
        # Generate summary line
        topic = "Voice chat"
        if user_messages:
            # Use first meaningful message as topic hint
            first_msg = user_messages[0][:40]
            topic = f"Voice: {first_msg}"
        
        summaries[conv_id] = {
            'time': time_str,
            'duration': duration_min,
            'exchanges': exchange_count,
            'topic': topic,
            'user_message_count': len(user_messages)
        }
    
    return summaries

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: voice-chat-summarizer.py YYYY-MM-DD", file=sys.stderr)
        sys.exit(1)
    
    date_str = sys.argv[1]
    summaries = summarize_voice_chats(date_str)
    
    if not summaries:
        print(json.dumps({"voice_chats": []}))
        sys.exit(0)
    
    # Output JSON
    result = {
        "voice_chats": [
            {
                "conversation_id": conv_id,
                **summary
            }
            for conv_id, summary in summaries.items()
        ]
    }
    
    print(json.dumps(result, ensure_ascii=False, indent=2))
