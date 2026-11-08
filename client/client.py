from openai import OpenAI
import time


client = OpenAI(base_url="http://localhost:8888/gemma-1b/v1", api_key="unused")


while True:
    prompt = str(input("\nUser: ").rstrip())
    stream = client.chat.completions.create(
        model="gemma-1b",
        messages=[{"role": "user", "content": prompt}],
        stream=True,
        max_tokens=500,
    )
    print("\nMikroLLM: ")
    for chunk in stream:
        if chunk.choices and chunk.choices[0].delta.content:
            print(chunk.choices[0].delta.content, end="", flush=True)
