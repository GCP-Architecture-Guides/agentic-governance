import os
from google import genai
from google.genai import types

class SimpleAgent:
    def __init__(self):
        pass

    def query(self, prompt: str) -> str:
        """Answers questions using Gemini."""
        client = genai.Client(vertexai=True, project="agentic-security-dev", location="us-central1")
        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=prompt,
        )
        return response.text

root_agent = SimpleAgent()
