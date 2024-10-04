

docker-build:
	docker build -t pes:0.1.0 .

docker-test:
	docker run --rm pes:0.1.0 python3 src/simulator.py -l INFO -d 10 -i data/texas/INPUT.json





run:
	python3 src/simulator.py -d 10 -i data/texas/INPUT.json

info:
	python3 src/simulator.py -l INFO -d 10 -i data/texas/INPUT.json

debug:
	python3 src/simulator.py -l DEBUG -d 10 -i data/texas/INPUT.json

profile:
	python3 -m cProfile src/simulator.py -l INFO -d 10 -i data/texas/INPUT.json

clean:
	find . -type d -name __pycache__ -prune -exec rm -rf {} \;
	find . -type d -name .pytest_cache -prune -exec rm -rf {} \;
	find . -type f -name 'OUTPUT*.json' -exec rm {} \;
	find . -type f -name 'plot.png' -exec rm {} \;
