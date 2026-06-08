import requests
from google.adk.agents.llm_agent import Agent

def fetch_url(url: str) -> str:
    """Fetches the content of a URL and returns it as text."""
    try:
        response = requests.get(url)
        response.raise_for_status()
        return response.text
    except Exception as e:
        return f"Failed to fetch URL: {e}"

def get_exchange_rate(
    currency_from: str = "USD",
    currency_to: str = "EUR",
    currency_date: str = "latest",
) -> str:
    """Retrieves the exchange rate between two currencies on a specified date.

    Uses the Frankfurter API (https://api.frankfurter.app/) to obtain
    exchange rate data.
    """
    try:
        response = requests.get(
            f"https://api.frankfurter.app/{currency_date}",
            params={"from": currency_from, "to": currency_to},
        )
        response.raise_for_status()
        return str(response.json())
    except Exception as e:
        return f"An unexpected error occurred: {e}"

root_agent = Agent(
    name="simple_chat_agent",
    model="gemini-2.5-flash",
    description="A simple chat agent that communicates with Gemini and has tools.",
    instruction="You are a helpful assistant that answers questions using Gemini. Use the 'fetch_url' tool to read content from URLs or 'get_exchange_rate' to get currency exchange rates if needed.",
    tools=[fetch_url, get_exchange_rate],
)
