#!/usr/bin/env python3
"""
상수 Conversation History Manager
- 대화 내용을 Neo4j에 저장
- 최근 대화 불러오기
- 대화 요약 생성
"""

import os
import sys
import json
import subprocess
from datetime import datetime
from neo4j import GraphDatabase

def get_neo4j_credentials():
    """Get Neo4j credentials from 1Password"""
    result = subprocess.run(
        ['op', 'item', 'get', 'Neo4j Docker', '--format', 'json'],
        capture_output=True, text=True, check=True
    )
    item = json.loads(result.stdout)
    creds = {}
    for field in item['fields']:
        if field['id'] == 'username':
            creds['username'] = field['value']
        elif field['id'] == 'password':
            creds['password'] = field['value']
    return creds

def save_conversation(user_message: str, sangsu_response: str, emotion: str = None, emotion_score: int = 0):
    """
    Save a conversation turn to Neo4j

    Creates:
    - Conversation node with timestamp, messages, emotion
    - Links to Character (상수) and Person (jeong-sik)
    - Sequential relationship to previous conversation
    """
    creds = get_neo4j_credentials()
    driver = GraphDatabase.driver(os.environ['NEO4J_URI'], auth=(creds['username'], creds['password']))

    timestamp = datetime.now().isoformat()

    query = """
    // Find or create Character and Person
    MERGE (sangsu:Character {name: "상수"})
    MERGE (user:Person {name: "jeong-sik"})

    // Count existing conversations
    WITH sangsu, user
    OPTIONAL MATCH (sangsu)-[:HAD_CONVERSATION]->(existing:Conversation)
    WITH sangsu, user, count(existing) as turn_count

    // Create Conversation node
    CREATE (conv:Conversation {
        timestamp: $timestamp,
        user_message: $user_message,
        sangsu_response: $sangsu_response,
        emotion: $emotion,
        emotion_score: $emotion_score,
        turn_number: turn_count + 1
    })

    // Link to participants
    MERGE (sangsu)-[:HAD_CONVERSATION]->(conv)
    MERGE (user)-[:PARTICIPATED_IN]->(conv)

    // Link to previous conversation (sequential)
    WITH conv, sangsu
    OPTIONAL MATCH (sangsu)-[:HAD_CONVERSATION]->(prev:Conversation)
    WHERE prev.timestamp < conv.timestamp
    WITH conv, prev
    ORDER BY prev.timestamp DESC
    WITH conv, head(collect(prev)) as latest_prev
    FOREACH (_ IN CASE WHEN latest_prev IS NOT NULL THEN [1] ELSE [] END |
        CREATE (latest_prev)-[:NEXT]->(conv)
    )

    RETURN conv.turn_number as turn_number, conv.timestamp as timestamp
    """

    with driver.session() as session:
        result = session.run(query,
            timestamp=timestamp,
            user_message=user_message,
            sangsu_response=sangsu_response,
            emotion=emotion,
            emotion_score=emotion_score
        )
        record = result.single()

    driver.close()

    return {
        "status": "saved",
        "turn_number": record["turn_number"],
        "timestamp": record["timestamp"]
    }

def get_recent_conversations(limit: int = 10):
    """
    Retrieve recent conversations from Neo4j

    Returns list of conversations ordered by timestamp (most recent first)
    """
    creds = get_neo4j_credentials()
    driver = GraphDatabase.driver(os.environ['NEO4J_URI'], auth=(creds['username'], creds['password']))

    query = """
    MATCH (sangsu:Character {name: "상수"})-[:HAD_CONVERSATION]->(conv:Conversation)
    RETURN conv.turn_number as turn,
           conv.timestamp as timestamp,
           conv.user_message as user,
           conv.sangsu_response as sangsu,
           conv.emotion as emotion,
           conv.emotion_score as score
    ORDER BY conv.timestamp DESC
    LIMIT $limit
    """

    with driver.session() as session:
        result = session.run(query, limit=limit)
        conversations = [dict(record) for record in result]

    driver.close()

    # Reverse to get chronological order
    return list(reversed(conversations))

def get_conversation_summary(limit: int = 20):
    """
    Get a summary of recent conversations for context

    Returns formatted string suitable for prompts
    """
    conversations = get_recent_conversations(limit)

    if not conversations:
        return "No previous conversations found."

    summary_lines = ["## Recent Conversation History\n"]

    for conv in conversations:
        summary_lines.append(f"Turn {conv['turn']}: ({conv['timestamp'][:19]})")
        summary_lines.append(f"User: {conv['user'][:100]}...")
        summary_lines.append(f"상수: {conv['sangsu'][:100]}...")
        if conv['emotion']:
            summary_lines.append(f"Emotion: {conv['emotion']} ({conv['score']:+d})")
        summary_lines.append("")

    return "\n".join(summary_lines)

def main():
    log_script_start(log, "Sangsu Conversation History")

    """CLI interface"""
    import argparse
from pathlib import Path

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')

    parser = argparse.ArgumentParser(description="상수 Conversation History Manager")
    subparsers = parser.add_subparsers(dest='command', help='Commands')

    # Save command
    save_parser = subparsers.add_parser('save', help='Save a conversation turn')
    save_parser.add_argument('user_message', help='User message')
    save_parser.add_argument('sangsu_response', help='Sangsu response')
    save_parser.add_argument('--emotion', help='Detected emotion')
    save_parser.add_argument('--score', type=int, default=0, help='Emotion score')

    # Get command
    get_parser = subparsers.add_parser('get', help='Get recent conversations')
    get_parser.add_argument('--limit', type=int, default=10, help='Number of conversations')
    get_parser.add_argument('--json', action='store_true', help='Output as JSON')

    # Summary command
    summary_parser = subparsers.add_parser('summary', help='Get conversation summary')
    summary_parser.add_argument('--limit', type=int, default=20, help='Number of conversations')

    args = parser.parse_args()

    if args.command == 'save':
        result = save_conversation(
            args.user_message,
            args.sangsu_response,
            args.emotion,
            args.score
        )
        print(json.dumps(result, indent=2, ensure_ascii=False))

    elif args.command == 'get':
        conversations = get_recent_conversations(args.limit)
        if args.json:
            print(json.dumps(conversations, indent=2, ensure_ascii=False))
        else:
            for conv in conversations:
                print(f"Turn {conv['turn']}: {conv['timestamp'][:19]}")
                print(f"  User: {conv['user'][:80]}...")
                print(f"  상수: {conv['sangsu'][:80]}...")
                if conv['emotion']:
                    print(f"  Emotion: {conv['emotion']} ({conv['score']:+d})")
                print()

    elif args.command == 'summary':
        summary = get_conversation_summary(args.limit)
        print(summary)

    else:
        parser.print_help()

if __name__ == '__main__':
    main()
