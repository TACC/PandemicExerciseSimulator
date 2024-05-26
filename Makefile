
run:
	python3 src/simulator.py -i data/texas/3D_Fast_Mild_P0-2009_PR-children_Tx-high-risk_Vacc-2009.json

info:
	python3 src/simulator.py -l INFO -i data/texas/3D_Fast_Mild_P0-2009_PR-children_Tx-high-risk_Vacc-2009.json

debug:
	python3 src/simulator.py -l DEBUG -i data/texas/3D_Fast_Mild_P0-2009_PR-children_Tx-high-risk_Vacc-2009.json

clean:
	find . -type d -name __pycache__ -prune -exec rm -rf {} \;
	find . -type f -name '*output.json' -exec rm {} \;
