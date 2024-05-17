

MAIN

	- read in files


	- create a bunch of instances of classes for each data type


	- Set up a thing to write log files


	- Call a simulator::run kind of function
		{
			- for each day of iteration...

			- handle distributions

			- apply treatments

			- modify stockpiles

			- simulate one step.  (what are node, time, parameters)

			- Travel

			- Write results

		}


	- Report summary statistics on what happened 


what are these
    Day numberOfDaysToSimulate,
    Network::RefPtr network,
    IDiseaseModel::RefPtr stochasticDiseaseModel,
    IDiseaseModel::RefPtr deterministicDiseaseModel,
    ITravelModel::RefPtr travelModel,
    const InterventionStockpileStrategies& distributions,
    const InterventionTreatments& actions,
    ModelParameters::RefPtr parameters,
    IWriter::RefPtr writer

