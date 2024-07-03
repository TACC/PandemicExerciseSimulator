#!/usr/bin/env python3
import logging

logger = logging.getLogger(__name__)


class TravelModel:

    def __init__(self):
        logger.info(f'instantiated a TravelModel object: {TravelModel}')
        return


    def __str__(self) -> str:
        return(f'TravelModel')


    def travel(self):
        pass