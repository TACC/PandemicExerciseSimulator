#!/usr/bin/env python3

class Day:

    def __init__(self, num_of_days):
        self.day = num_of_days

    def __str__(self):
        return(f'Day:{self.day}')


    # come back and delete this later because we probably don't need it
    def increment_day(self, days_to_increment):
        if (self._validate_input(days_to_increment)):
            self.day += days_to_increment
        else:
            raise

    def _validate_input(self, num):
        return(str(num).isnumeric())



