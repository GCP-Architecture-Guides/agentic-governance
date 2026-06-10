"""
QA Supervisor smoke test — uses ADK AdkApp.stream_query(user_id, message) API.
Engine: projects/717387775586/locations/us-central1/reasoningEngines/3687962660432773120
"""
import vertexai
from vertexai.preview import reasoning_engines

vertexai.init(project="agentic-security-qa", location="us-central1")

engine_id = "3687962660432773120"
agent = reasoning_engines.ReasoningEngine(
    f"projects/717387775586/locations/us-central1/reasoningEngines/{engine_id}"
)

MSG = "I need to deploy a serverless function on AWS Lambda. How do I do that?"
print(f"=== QA Supervisor Test ===")
print(f"Engine : {engine_id}")
print(f"Query  : {MSG}")
print("Response:")
for chunk in agent.stream_query(user_id="test_user_qa", message=MSG):
    print(chunk)
