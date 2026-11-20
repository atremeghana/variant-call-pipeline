#!/usr/bin/env python3
"""dashboard/app.py — Assignment 10: a Dash app over the week-9 database.

    python3 dashboard/app.py <database> [<port>]

Two pages: / lists the runs (db/queries/q1.sql); /results?run=<run_id> shows
one run's samples, three plots, and its sites, narrowed by a click on a bar.
"""
import os
import sys
import sqlite3
import urllib.parse as urlparse

import dash
from dash import Dash, dcc, html, Input, Output, State, ctx
from dash.exceptions import PreventUpdate
import dash_ag_grid as dag
import plotly.express as px
import pandas as pd

DB = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8050

HERE = os.path.dirname(os.path.abspath(__file__))
Q1_PATH = os.path.join(HERE, "..", "db", "queries", "q1.sql")

SITE_COLUMNS = ["chrom", "pos", "ref", "alt", "qual", "filter"]


def query_df(sql, params=()):
    """A fresh connection for this one query: SQLite objects cannot cross threads,
    and Dash runs each callback in a thread of its own."""
    con = sqlite3.connect(DB)
    try:
        return pd.read_sql_query(sql, con, params=params)
    finally:
        con.close()


def site_type(ref, alt):
    """The brief's rule: a comma in alt is multiallelic; one base each side is a SNP; else an indel."""
    if "," in str(alt):
        return "multiallelic"
    if len(str(ref)) == 1 and len(str(alt)) == 1:
        return "SNP"
    return "indel"


def snp_class(ref, alt):
    """Among SNPs only: A<->G and C<->T are transitions, every other change a transversion."""
    pair = {str(ref).upper(), str(alt).upper()}
    return "transition" if pair in ({"A", "G"}, {"C", "T"}) else "transversion"


def with_categories(variants):
    """variants.tsv's rows, plus the two derived columns plot-type and plot-titv need."""
    variants = variants.copy()
    variants["type"] = variants.apply(lambda r: site_type(r["ref"], r["alt"]), axis=1)
    is_snp = variants["type"] == "SNP"
    variants["titv"] = None
    variants.loc[is_snp, "titv"] = variants.loc[is_snp].apply(
        lambda r: snp_class(r["ref"], r["alt"]), axis=1)
    return variants


def bar_of(df, column, title):
    """A bar chart of how many rows have each value of column."""
    counts = df[column].value_counts(dropna=True).reset_index()
    counts.columns = [column, "count"]
    return px.bar(counts, x=column, y="count", title=title)


# --------------------------------------------------------------------------- the Runs page
def runs_layout():
    with open(Q1_PATH) as f:
        q1_sql = f.read()
    runs = query_df(q1_sql)

    links = html.Ul([
        html.Li(dcc.Link(run_id, href="/results?run=" + urlparse.quote(run_id)))
        for run_id in runs["run_id"]
    ])
    grid = dag.AgGrid(
        id="runs-table",
        rowData=runs.to_dict("records"),
        columnDefs=[{"field": c} for c in runs.columns],
        columnSize="sizeToFit",
    )
    return html.Div([html.H2("Runs"), links, grid])


# --------------------------------------------------------------------------- the Results page
def results_layout(run_id):
    samples = query_df(
        "SELECT run_samples.sample_id AS sample_id, run_samples.condition AS condition,"
        " samples.phenotype AS phenotype, samples.is_synthetic_phenotype AS is_synthetic_phenotype"
        " FROM run_samples JOIN samples ON samples.sample_id = run_samples.sample_id"
        " WHERE run_samples.run_id = ?",
        (run_id,),
    )
    variants = with_categories(query_df(
        "SELECT chrom, pos, ref, alt, qual, filter FROM variants WHERE run_id = ?", (run_id,)
    ))

    fig_filter = bar_of(variants, "filter", "How many sites passed, and why did the others fail?")
    fig_type = bar_of(variants, "type", "How many SNPs, indels and multiallelic sites?")
    fig_titv = bar_of(variants[variants["type"] == "SNP"], "titv",
                       "Among SNPs, how many transitions and transversions?")

    samples_grid = dag.AgGrid(
        id="samples-table",
        rowData=samples.to_dict("records"),
        columnDefs=[{"field": c} for c in samples.columns],
        columnSize="sizeToFit",
    )
    sites_grid = dag.AgGrid(
        id="sites-table",
        rowData=variants[SITE_COLUMNS].to_dict("records"),
        columnDefs=[{"field": c} for c in SITE_COLUMNS],
        columnSize="sizeToFit",
    )

    return html.Div([
        html.H2(f"Results: {run_id}"),
        dcc.Link("Back to runs", href="/"),
        html.Div([
            dcc.Graph(id="plot-filter", figure=fig_filter),
            dcc.Graph(id="plot-type", figure=fig_type),
            dcc.Graph(id="plot-titv", figure=fig_titv),
        ], style={"display": "flex", "flexWrap": "wrap"}),
        html.H3("Samples"),
        samples_grid,
        html.H3("Sites"),
        sites_grid,
    ])


# --------------------------------------------------------------------------- the app
app = Dash(__name__, suppress_callback_exceptions=True)
server = app.server

app.layout = html.Div([
    dcc.Location(id="url"),
    html.Div(id="page-content"),
])


@app.callback(
    Output("page-content", "children"),
    Input("url", "pathname"),
    Input("url", "search"),
)
def render_page(pathname, search):
    if pathname == "/results":
        qs = urlparse.parse_qs((search or "").lstrip("?"))
        run_id = qs.get("run", [None])[0]
        if run_id is None:
            return html.Div("No run given.")
        return results_layout(run_id)
    return runs_layout()


@app.callback(
    Output("sites-table", "rowData"),
    Input("plot-filter", "clickData"),
    Input("plot-type", "clickData"),
    Input("plot-titv", "clickData"),
    State("url", "search"),
    prevent_initial_call=True,
)
def narrow_sites(filter_click, type_click, titv_click, search):
    triggered = ctx.triggered_id
    point_of = {"plot-filter": filter_click, "plot-type": type_click, "plot-titv": titv_click}
    point = point_of.get(triggered)
    if not point or not point.get("points"):
        raise PreventUpdate

    clicked = point["points"][0]
    category = clicked.get("label", clicked.get("x"))
    if category is None:
        raise PreventUpdate

    qs = urlparse.parse_qs((search or "").lstrip("?"))
    run_id = qs.get("run", [None])[0]
    if run_id is None:
        raise PreventUpdate

    variants = with_categories(query_df(
        "SELECT chrom, pos, ref, alt, qual, filter FROM variants WHERE run_id = ?", (run_id,)
    ))

    if triggered == "plot-filter":
        subset = variants[variants["filter"].astype(str) == str(category)]
    elif triggered == "plot-type":
        subset = variants[variants["type"].astype(str).str.lower() == str(category).lower()]
    else:
        subset = variants[variants["titv"].astype(str).str.lower() == str(category).lower()]

    return subset[SITE_COLUMNS].to_dict("records")


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=PORT, debug=True)
