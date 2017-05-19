docker-build:
	docker build -t vernemq .

# Note: clean-slate each time
docker-up:
	sudo rm -rf ./data
	aws s3 rm "s3://vernemq-discovery/" --recursive
	docker-compose up
