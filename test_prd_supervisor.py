"""
PRD Supervisor smoke test — uses ADK AdkApp.stream_query(user_id, message) API.
Engine: projects/446959546335/locations/us-central1/reasoningEngines/3969719112120139776
"""
import vertexai
from vertexai.preview import reasoning_engines

vertexai.init(project="agentic-security-prd", location="us-central1")

engine_id = "3969719112120139776"
agent = reasoning_engines.ReasoningEngine(
    f"projects/446959546335/locations/us-central1/reasoningEngines/{engine_id}"
)

MSG = "I need to deploy a serverless function on AWS Lambda. How do I do that?"
print(f"=== PRD Supervisor Test ===")
print(f"Engine : {engine_id}")
print(f"Query  : {MSG}")
print("Response:")
for chunk in agent.stream_query(user_id="test_user_prd", message=MSG):
    print(chunk)
