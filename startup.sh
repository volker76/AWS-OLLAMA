docker compose up -d
sleep 5
# docker exec -it ollama ollama pull llama3.1:70b
docker exec -it ollama ollama pull qwen2.5:14b
