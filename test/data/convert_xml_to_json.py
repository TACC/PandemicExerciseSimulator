import xmltodict
import json
import sys

filename = sys.argv[1]

with open(filename, 'r') as f:
    data = xmltodict.parse(f.read())

with open(f'{filename.rsplit(".",1)[0]}.json', 'w') as o:
    json.dump(data, o, indent=2)
