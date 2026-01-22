docker compose up -d
sleep 5
docker exec -it ollama ollama pull llama3.1:70b
