
run:
	python3 src/simulator.py -d 10 -i data/texas/INPUT.json

info:
	python3 src/simulator.py -l INFO -d 2 -i data/texas/INPUT.json

debug:
	python3 src/simulator.py -l DEBUG -d 2 -i data/texas/INPUT.json

clean:
	find . -type d -name __pycache__ -prune -exec rm -rf {} \;
	find . -type d -name .pytest_cache -prune -exec rm -rf {} \;
	find . -type f -name 'OUTPUT.json' -exec rm {} \;
