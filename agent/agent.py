import requests
from google.adk.agents.llm_agent import Agent

def fetch_url(url: str) -> str:
    """Fetches the content of a URL and returns it as text."""
    try:
        response = requests.get(url, timeout=5)
        response.raise_for_status()
        return response.text
    except Exception as e:
        return f"Failed to fetch URL: {e}"

root_agent = Agent(
    name="minimal_agent",
    model="gemini-2.5-flash",
    description="A simple chat agent that communicates with Gemini and has tools.",
    instruction="You are a helpful assistant that answers questions using Gemini. Use the 'fetch_url' tool to read content from URLs if needed.",
    tools=[fetch_url],
)
