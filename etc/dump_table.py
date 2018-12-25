#!/usr/bin/env python3

import argparse
import csv
import sys

import boto3

def parse_args():
    argparser = argparse.ArgumentParser(description='Dump DynamoDB table as CVS')
    argparser.add_argument('table_name', help='table name to export')
    argparser.add_argument(
        '--out', '-o', help='CSV output destination (default: stdout)',
        default=sys.stdout, type=argparse.FileType('w'))
    return argparser.parse_args()

def table_items(table):
    args = {}
    while True:
        response = table.scan(**args)
        yield from response['Items']

        last_evaluated_key = response.get('LastEvaluatedKey', None)
        if not last_evaluated_key:
            break

        args['LastEvaluatedKey'] = last_evaluated_key


def discover_field_names(table):
    field_names = set()
    for item in table_items(table):
        field_names.update(item.keys())

    return field_names


def dump_table(table, writer):
    for item in table_items(table):
        writer.writerow(item)


def main():
    args = parse_args()
    dynamodb = boto3.resource('dynamodb')
    table = dynamodb.Table(args.table_name)
    field_names = discover_field_names(table)
    writer = csv.DictWriter(args.out, extrasaction='ignore', fieldnames=field_names,
                            delimiter=',', quotechar='"', quoting=csv.QUOTE_MINIMAL)
    writer.writeheader()
    dump_table(table, writer)

if __name__ == '__main__':
    main()
