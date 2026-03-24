#!/usr/bin/env python3
"""
Miseon Agent with Neo4j Memory Integration
Complete implementation of memory cycle
"""
import sys
sys.path.insert(0, '/Users/vincent.dev/me/scripts/lib')

from context_loader import ContextLoader
from conversation_logger import ConversationLogger


def launch_miseon_with_memory(user_name: str):
    """
    Launch Miseon agent with full memory integration

    Args:
        user_name: User's name (e.g., '송지영')
    """
    agent_name = "Miseon"

    print(f"\n🧠 Launching Miseon for {user_name}...")
    print("="*60)

    # ==================================================================
    # Stage 0: Load Past Conversations
    # ==================================================================
    print("\n📚 Stage 0: Loading past conversations...")

    loader = ContextLoader()
    messages = loader.load_conversation_messages(
        user_name=user_name,
        agent_name=agent_name,
        days=7,
        limit=100
    )

    print(f"✅ Loaded {len(messages)} past messages")

    if messages:
        print("\n📝 Recent conversation (last 5 messages):")
        for msg in messages[-5:]:
            speaker = msg['speaker']
            content = msg['content'][:60] + '...' if len(msg['content']) > 60 else msg['content']
            timestamp = msg['timestamp'][:10] if msg['timestamp'] else 'N/A'
            print(f"  [{timestamp}] {speaker}: {content}")

        # Build context string
        context_messages = messages[-10:]  # Last 10 for context
        context_str = "\n".join([
            f"{msg['speaker']}: {msg['content']}"
            for msg in context_messages
        ])
    else:
        print("\n💡 No past messages - this is a new conversation")
        context_str = ""

    # ==================================================================
    # Stage 1: Load Base Identity
    # ==================================================================
    print("\n🎭 Stage 1: Loading Miseon's identity...")

    identity = loader.load_identity(agent_name)

    if identity:
        print(f"✅ Identity loaded:")
        print(f"  Role: {identity['role']}")
        print(f"  Traits: {', '.join(identity['traits'][:5])}")
        print(f"  Interests: {', '.join(identity['interests'][:5])}")
        print(f"  Relationships: {len(identity['relationships'])} connections")
    else:
        print("⚠️ Identity not found in Neo4j")
        return

    # ==================================================================
    # Stage 2: Load User Intimacy
    # ==================================================================
    print(f"\n💝 Stage 2: Checking intimacy with {user_name}...")

    intimacy_data = loader.calculate_intimacy_score(user_name, agent_name)

    intimacy_level = intimacy_data['final_score']
    conversation_count = intimacy_data['conversation_count']
    days_since_last = intimacy_data['days_since_last']

    print(f"✅ Intimacy: {intimacy_level}/10")
    print(f"  Conversations: {conversation_count}")
    if days_since_last is not None:
        print(f"  Last talked: {days_since_last} days ago")

    # ==================================================================
    # Stage 3: Determine Tone & Greeting
    # ==================================================================
    print("\n🎤 Stage 3: Preparing voice mode...")

    # Tone by intimacy
    if intimacy_level >= 8:
        tone = "casual"
        greeting_style = f"{user_name}야" if user_name == '송지영' else f"{user_name}님"
    elif intimacy_level >= 5:
        tone = "friendly"
        greeting_style = f"{user_name}님"
    else:
        tone = "formal"
        greeting_style = f"{user_name}님"

    # Generate context-aware greeting
    if messages:
        # Reference past conversation
        last_topic = extract_last_topic(messages[-5:])
        initial_greeting = f"{greeting_style}, 어제 {last_topic} 얘기 기억나요. 괜찮으세요?"
    else:
        # New conversation
        initial_greeting = f"{greeting_style}, 안녕하세요! 반가워요."

    print(f"✅ Tone: {tone}")
    print(f"✅ Greeting: {initial_greeting}")

    # ==================================================================
    # Stage 4-10: Conversation Loop (Placeholder)
    # ==================================================================
    print("\n🎙️ Voice conversation would start here...")
    print(f"  Context: {len(context_messages) if messages else 0} messages loaded")
    print(f"  Intimacy: {intimacy_level}/10 ({tone} tone)")
    print(f"  First message: \"{initial_greeting}\"")

    # In real implementation:
    # logger = ConversationLogger()
    # conv_id = logger.start_conversation(user_name, agent_name)
    #
    # mcp__voicemode__converse(
    #     message=initial_greeting,
    #     wait_for_response=True,
    #     ...
    # )
    #
    # while in_conversation:
    #     user_input = get_voice()
    #     logger.log_message('user', user_input)
    #     response = generate_response(user_input, context_str)
    #     logger.log_message('agent', response)
    #     speak(response)
    #
    # logger.end_conversation("summary")

    print("\n" + "="*60)
    print("✅ Memory system ready! (Voice mode not activated in test)")


def extract_last_topic(messages):
    """Extract main topic from recent messages (simple version)"""
    if not messages:
        return "지난 대화"

    # Simple keyword extraction
    keywords = []
    for msg in messages:
        content = msg['content'].lower()
        if '권고사직' in content or '퇴사' in content:
            keywords.append('권고사직')
        if '포트폴리오' in content:
            keywords.append('포트폴리오')
        if '여행' in content:
            keywords.append('여행')
        if '시드니' in content:
            keywords.append('시드니')

    if keywords:
        return keywords[-1]  # Most recent topic
    return "지난 대화"


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description='Launch Miseon with memory')
    parser.add_argument('user_name', help='User name (e.g., 송지영)')
    parser.add_argument('--test', action='store_true', help='Test mode (no voice)')

    args = parser.parse_args()

    launch_miseon_with_memory(args.user_name)
