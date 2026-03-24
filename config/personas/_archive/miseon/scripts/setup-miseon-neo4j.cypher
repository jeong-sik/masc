// Setup 박미선 (DataExpert) & 송지영 베프 관계 in Neo4j
// Date: 2025-11-02

// 1. DataExpert 노드 생성 (박미선)
MERGE (d:DataExpert {id: "miseon-park"})
ON CREATE SET
  d.name = "박미선",
  d.role = "데이터 구축가/PO/PM",
  d.voice = "rachel",
  d.created_at = datetime()
ON MATCH SET
  d.role = "데이터 구축가/PO/PM",
  d.voice = "rachel";

// 2. Person 노드 생성 (송지영)
MERGE (jy:Person {id: "jiyoung-song"})
ON CREATE SET
  jy.name = "송지영",
  jy.created_at = datetime(),
  jy.last_interaction = datetime()
ON MATCH SET
  jy.name = "송지영",
  jy.last_interaction = datetime();

// 3. HAS_INTIMACY 관계 (송지영 → 박미선, 베프 레벨)
MATCH (jy:Person {id: "jiyoung-song"})
MATCH (d:DataExpert {id: "miseon-park"})
MERGE (jy)-[r:HAS_INTIMACY]->(d)
ON CREATE SET
  r.level = 10,
  r.interactions = 2000,
  r.last_updated = datetime(),
  r.decay_rate = 0.01
ON MATCH SET
  r.level = 10,
  r.interactions = 2000,
  r.last_updated = datetime(),
  r.decay_rate = 0.01;

// 4. BEST_FRIEND 관계 (양방향)
MATCH (jy:Person {id: "jiyoung-song"})
MATCH (d:DataExpert {id: "miseon-park"})
MERGE (jy)-[:BEST_FRIEND]->(d)
MERGE (d)-[:BEST_FRIEND]->(jy);

// 5. 확인 쿼리
MATCH (jy:Person {id: "jiyoung-song"})-[r:HAS_INTIMACY]->(d:DataExpert {id: "miseon-park"})
RETURN jy.name AS user, d.name AS expert, d.role AS role, r.level AS intimacy_level, r.interactions AS total_interactions;

MATCH (jy:Person {id: "jiyoung-song"})-[:BEST_FRIEND]-(d:DataExpert {id: "miseon-park"})
RETURN jy.name AS user, d.name AS expert, "BEST_FRIEND" AS relationship;
